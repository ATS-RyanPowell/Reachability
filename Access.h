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
 
 
#ifndef __ACCESS_H
#define __ACCESS_H


#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>

/** Project version number */
FOUNDATION_EXPORT double AccessVersionNumber;

/** Project version string */
FOUNDATION_EXPORT const unsigned char AccessVersionString[];


extern NSString *const kAccessChangedNotification;

/* Apple NetworkStatus Compatible Names. */
typedef NS_ENUM(NSInteger, NetworkStatus) {
    NotAccessable = 0,
    AccessableViaWiFi = 2,
    AccessableViaWWAN = 1
};

@class Access;

typedef void (^NetworkAccessable)(Access * Access);
typedef void (^NetworkUnaccessable)(Access * Access);
typedef void (^NetworkAccessibility)(Access * Access, SCNetworkConnectionFlags flags);


@interface Access : NSObject

@property (nonatomic, copy) NetworkAccessable    accessableBlock;
@property (nonatomic, copy) NetworkUnaccessable  unaccessableBlock;
@property (nonatomic, copy) NetworkAccessibility accessibilityBlock;

@property (nonatomic, assign) BOOL accessableOnWWAN;


+(bool) hasInternetConnection;
/* This is identical to the function above, but is here to maintain
 compatibility with Apples original code. (see .m) */
+(instancetype) accessWithHostName:(NSString*)hostname;
+(instancetype) accessForInternetConnection;
+(instancetype) accessWithAddress:(void *)hostAddress;
+(instancetype) accessForLocalWiFi;

-(instancetype) initWithAccessRef:(SCNetworkReachabilityRef)ref;

-(BOOL) startNotifier;
-(void) stopNotifier;

-(BOOL) isAccessable;
-(BOOL) isAccessableViaWWAN;
-(BOOL) isAccessableViaWiFi;

/* WWAN may be available, but not active until a connection has been established.
   WiFi may require a connection for VPN on Demand. */
-(BOOL) isConnectionRequired; /* Identical DDG variant. */
-(BOOL) connectionRequired; /* Apple's routine. */
-(BOOL) isConnectionOnDemand; /* Dynamic, on demand connection? */
-(BOOL) isInterventionRequired; /* Is user intervention required? */

-(NetworkStatus) currentAccessStatus;
-(SCNetworkReachabilityFlags) accessFlags;
-(NSString*) currentAccessString;
-(NSString*) currentAccessFlags;

@end


#endif /* __ACCESS_H */
