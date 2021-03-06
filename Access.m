/*
 Copyright (c) 2011, Tony Million.
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.
 
 2. Redistributions in binary form must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided with the distribution.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE. 
 */

#import "Access.h"

#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>


NSString *const kAccessChangedNotification = @"kAccessChangedNotification";


@interface Access ()

@property (nonatomic, assign) SCNetworkReachabilityRef  accessRef;
@property (nonatomic, strong) dispatch_queue_t          accessSerialQueue;
@property (nonatomic, strong) id                        accessObject;

-(void)accessChanged:(SCNetworkReachabilityFlags)flags;
-(BOOL)isAccessableWithFlags:(SCNetworkReachabilityFlags)flags;

@end


static NSString *accessFlags(SCNetworkReachabilityFlags flags) 
{
    return [NSString stringWithFormat:@"%c%c %c%c%c%c%c%c%c",
#if	TARGET_OS_IPHONE
            (flags & kSCNetworkReachabilityFlagsIsWWAN)               ? 'W' : '-',
#else
            'X',
#endif
             (flags & kSCNetworkReachabilityFlagsReachable)            ? 'R' : '-',
             (flags & kSCNetworkReachabilityFlagsConnectionRequired)   ? 'c' : '-',
             (flags & kSCNetworkReachabilityFlagsTransientConnection)  ? 't' : '-',
             (flags & kSCNetworkReachabilityFlagsInterventionRequired) ? 'i' : '-',
             (flags & kSCNetworkReachabilityFlagsConnectionOnTraffic)  ? 'C' : '-',
             (flags & kSCNetworkReachabilityFlagsConnectionOnDemand)   ? 'D' : '-',
             (flags & kSCNetworkReachabilityFlagsIsLocalAddress)       ? 'l' : '-',
             (flags & kSCNetworkReachabilityFlagsIsDirect)             ? 'd' : '-'];
}

// Start listening for Access notifications on the current run loop
static void TMAccessCallback(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void* info) 
{
#pragma unused (target)

    Access *access = ((__bridge Access*)info);

    // We probably don't need an autoreleasepool here, as GCD docs state each queue has its own autorelease pool,
    // but what the heck eh?
    @autoreleasepool 
    {
        [access accessChanged:flags];
    }
}


@implementation Access

#pragma mark - Class Constructor Methods

+(bool) hasInternetConnection
{
    bool hasConnection = NO;
    
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;

    SCNetworkReachabilityRef ref = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr*)&zeroAddress);
    
    if (ref)
    {
        Access *obj = [[Access alloc] initWithAccessRef:ref];
        
        hasConnection = obj.isAccessable;
    }
    
    return hasConnection;
}

+(instancetype)accessWithHostName:(NSString*)hostname
{
    return [Access accessWithHostname:hostname];
}

+(instancetype)accessWithHostname:(NSString*)hostname
{
    SCNetworkReachabilityRef ref = SCNetworkReachabilityCreateWithName(NULL, [hostname UTF8String]);
    if (ref) 
    {
        id access = [[self alloc] initWithAccessRef:ref];

        return access;
    }
    
    return nil;
}

+(instancetype)accessWithAddress:(void *)hostAddress
{
    SCNetworkReachabilityRef ref = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, (const struct sockaddr*)hostAddress);
    if (ref) 
    {
        id access = [[self alloc] initWithAccessRef:ref];
        
        return access;
    }
    
    return nil;
}

+(instancetype)accessForInternetConnection
{
    struct sockaddr_in zeroAddress;
    bzero(&zeroAddress, sizeof(zeroAddress));
    zeroAddress.sin_len = sizeof(zeroAddress);
    zeroAddress.sin_family = AF_INET;
    
    return [self accessWithAddress:&zeroAddress];
}

+(instancetype)accessForLocalWiFi
{
    struct sockaddr_in localWifiAddress;
    bzero(&localWifiAddress, sizeof(localWifiAddress));
    localWifiAddress.sin_len            = sizeof(localWifiAddress);
    localWifiAddress.sin_family         = AF_INET;
    // IN_LINKLOCALNETNUM is defined in <netinet/in.h> as 169.254.0.0
    localWifiAddress.sin_addr.s_addr    = htonl(IN_LINKLOCALNETNUM);
    
    return [self accessWithAddress:&localWifiAddress];
}


// Initialization methods

-(instancetype)initWithAccessRef:(SCNetworkReachabilityRef)ref
{
    self = [super init];
    if (self != nil) 
    {
        self.accessableOnWWAN = YES;
        self.accessRef = ref;

        // We need to create a serial queue.
        // We allocate this once for the lifetime of the notifier.

        self.accessSerialQueue = dispatch_queue_create("com.network.accessibility", NULL);
    }
    
    return self;    
}

-(void)dealloc
{
    [self stopNotifier];

    if(self.accessRef)
    {
        CFRelease(self.accessRef);
        self.accessRef = nil;
    }

	self.accessableBlock          = nil;
    self.unaccessableBlock        = nil;
    self.accessibilityBlock       = nil;
    self.accessSerialQueue = nil;
}

#pragma mark - Notifier Methods

// Notifier 
// NOTE: This uses GCD to trigger the blocks - they *WILL NOT* be called on THE MAIN THREAD
// - In other words DO NOT DO ANY UI UPDATES IN THE BLOCKS.
//   INSTEAD USE dispatch_async(dispatch_get_main_queue(), ^{UISTUFF}) (or dispatch_sync if you want)

-(BOOL)startNotifier
{
    // allow start notifier to be called multiple times
    if(self.accessObject && (self.accessObject == self))
    {
        return YES;
    }


    SCNetworkReachabilityContext    context = { 0, NULL, NULL, NULL, NULL };
    context.info = (__bridge void *)self;

    if(SCNetworkReachabilitySetCallback(self.accessRef, TMAccessCallback, &context))
    {
        // Set it as our Access queue, which will retain the queue
        if(SCNetworkReachabilitySetDispatchQueue(self.accessRef, self.accessSerialQueue))
        {
            // this should do a retain on ourself, so as long as we're in notifier mode we shouldn't disappear out from under ourselves
            // woah
            self.accessObject = self;
            return YES;
        }
        else
        {
#ifdef DEBUG
            NSLog(@"SCNetworkReachabilitySetDispatchQueue() failed: %s", SCErrorString(SCError()));
#endif

            // UH OH - FAILURE - stop any callbacks!
            SCNetworkReachabilitySetCallback(self.accessRef, NULL, NULL);
        }
    }
    else
    {
#ifdef DEBUG
        NSLog(@"SCNetworkReachabilitySetCallback() failed: %s", SCErrorString(SCError()));
#endif
    }

    // if we get here we fail at the internet
    self.accessObject = nil;
    return NO;
}

-(void)stopNotifier
{
    // First stop, any callbacks!
    SCNetworkReachabilitySetCallback(self.accessRef, NULL, NULL);
    
    // Unregister target from the GCD serial dispatch queue.
    SCNetworkReachabilitySetDispatchQueue(self.accessRef, NULL);

    self.accessObject = nil;
}

#pragma mark - Access tests

// This is for the case where you flick the airplane mode;
// you end up getting something like this:
//Access: WR ct-----
//Access: -- -------
//Access: WR ct-----
//Access: -- -------
// We treat this as 4 UNREACHABLE triggers - really apple should do better than this

#define testcase (kSCNetworkReachabilityFlagsConnectionRequired | kSCNetworkReachabilityFlagsTransientConnection)

-(BOOL)isAccessableWithFlags:(SCNetworkReachabilityFlags)flags
{
    BOOL connectionUP = YES;
    
    if(!(flags & kSCNetworkReachabilityFlagsReachable))
        connectionUP = NO;
    
    if( (flags & testcase) == testcase )
        connectionUP = NO;
    
#if	TARGET_OS_IPHONE
    if(flags & kSCNetworkReachabilityFlagsIsWWAN)
    {
        // We're on 3G.
        if(!self.accessableOnWWAN)
        {
            // We don't want to connect when on 3G.
            connectionUP = NO;
        }
    }
#endif
    
    return connectionUP;
}

-(BOOL)isAccessable
{
    SCNetworkReachabilityFlags flags;  
    
    if(!SCNetworkReachabilityGetFlags(self.accessRef, &flags))
        return NO;
    
    return [self isAccessableWithFlags:flags];
}

-(BOOL)isAccessableViaWWAN
{
#if	TARGET_OS_IPHONE

    SCNetworkReachabilityFlags flags = 0;
    
    if(SCNetworkReachabilityGetFlags(self.accessRef, &flags))
    {
        // Check we're REACHABLE
        if(flags & kSCNetworkReachabilityFlagsReachable)
        {
            // Now, check we're on WWAN
            if(flags & kSCNetworkReachabilityFlagsIsWWAN)
            {
                return YES;
            }
        }
    }
#endif
    
    return NO;
}

-(BOOL)isAccessableViaWiFi
{
    SCNetworkReachabilityFlags flags = 0;
    
    if(SCNetworkReachabilityGetFlags(self.accessRef, &flags))
    {
        // Check we're reachable
        if((flags & kSCNetworkReachabilityFlagsReachable))
        {
#if	TARGET_OS_IPHONE
            // Check we're NOT on WWAN
            if((flags & kSCNetworkReachabilityFlagsIsWWAN))
            {
                return NO;
            }
#endif
            return YES;
        }
    }
    
    return NO;
}


// WWAN may be available, but not active until a connection has been established.
// WiFi may require a connection for VPN on Demand.
-(BOOL)isConnectionRequired
{
    return [self connectionRequired];
}

-(BOOL)connectionRequired
{
    SCNetworkReachabilityFlags flags;
	
	if(SCNetworkReachabilityGetFlags(self.accessRef, &flags))
    {
		return (flags & kSCNetworkReachabilityFlagsConnectionRequired);
	}
    
    return NO;
}

// Dynamic, on demand connection?
-(BOOL)isConnectionOnDemand
{
	SCNetworkReachabilityFlags flags;
	
	if (SCNetworkReachabilityGetFlags(self.accessRef, &flags))
    {
		return ((flags & kSCNetworkReachabilityFlagsConnectionRequired) &&
				(flags & (kSCNetworkReachabilityFlagsConnectionOnTraffic | kSCNetworkReachabilityFlagsConnectionOnDemand)));
	}
	
	return NO;
}

// Is user intervention required?
-(BOOL)isInterventionRequired
{
    SCNetworkReachabilityFlags flags;
	
	if (SCNetworkReachabilityGetFlags(self.accessRef, &flags))
    {
		return ((flags & kSCNetworkReachabilityFlagsConnectionRequired) &&
				(flags & kSCNetworkReachabilityFlagsInterventionRequired));
	}
	
	return NO;
}


#pragma mark - Access status stuff

-(NetworkStatus)currentAccessStatus
{
    if([self isAccessable])
    {
        if([self isAccessableViaWiFi])
            return AccessableViaWiFi;
        
#if	TARGET_OS_IPHONE
        return AccessableViaWWAN;
#endif
    }
    
    return NotAccessable;
}

-(SCNetworkReachabilityFlags) accessFlags
{
    SCNetworkReachabilityFlags flags = 0;
    
    if(SCNetworkReachabilityGetFlags(self.accessRef, &flags)) 
    {
        return flags;
    }
    
    return 0;
}

-(NSString*)currentAccessString
{
	NetworkStatus temp = [self currentAccessStatus];
	
	if(temp == AccessableViaWWAN)
	{
        // Updated for the fact that we have CDMA phones now!
		return NSLocalizedString(@"Cellular", @"");
	}
	if (temp == AccessableViaWiFi)
	{
		return NSLocalizedString(@"WiFi", @"");
	}
	
	return NSLocalizedString(@"No Connection", @"");
}

-(NSString*)currentAccessFlags
{
    return accessFlags([self accessFlags]);
}

#pragma mark - Callback function calls this method

-(void)accessChanged:(SCNetworkReachabilityFlags)flags
{
    if([self isAccessableWithFlags:flags])
    {
        if(self.accessableBlock)
        {
            self.accessableBlock(self);
        }
    }
    else
    {
        if(self.unaccessableBlock)
        {
            self.unaccessableBlock(self);
        }
    }
    
    if(self.accessibilityBlock)
    {
        self.accessibilityBlock(self, flags);
    }
    
    // this makes sure the change notification happens on the MAIN THREAD
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kAccessChangedNotification 
                                                            object:self];
    });
}

#pragma mark - Debug Description

- (NSString *) description
{
    NSString *description = [NSString stringWithFormat:@"<%@: %#x (%@)>",
                             NSStringFromClass([self class]), (unsigned int) self, [self currentAccessFlags]];
    return description;
}

@end
