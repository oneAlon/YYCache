//
//  ViewController.m
//  CacheBenchmark
//
//  Created by ibireme on 2017/6/29.
//  Copyright © 2017年 ibireme. All rights reserved.
//

#import "ViewController.h"
#include "Benchmark.h"
#import "YYCache.h"

//static NSUInteger count = 0;

@interface MyObject : NSObject

@property (nonatomic, unsafe_unretained) NSString *name;

@end

@implementation MyObject

- (void)_trimRecursively {
//    __weak typeof(self) _self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.00000001 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
//        __strong typeof(_self) strongSelf = _self;
//        if (!strongSelf) return;
        [self _trimRecursively];
    });
}

- (void)_trimInBackground {
    dispatch_queue_t _queue = dispatch_queue_create("com.ibireme.cache.memory", DISPATCH_QUEUE_SERIAL);
    dispatch_async(_queue, ^{
        NSLog(@"%@", self);
    });
}

@end

@interface ViewController ()

@property (nonatomic, strong) YYMemoryCache *cache;
@property (nonatomic, strong) MyObject *obj;

@end

@implementation ViewController



- (void)viewDidLoad {
    [super viewDidLoad];
    
    YYCache *cache = [YYCache cacheWithName:@"myCache"];
    YYCache *cache1 = [YYCache cacheWithName:@"myCache"];
    [cache setObject:@"myValue" forKey:@"myKey" withBlock:^{
        
    }];
    cache.diskCache.customFileNameBlock = ^NSString * _Nonnull(NSString * _Nonnull key) {
        return [NSString stringWithFormat:@"%@+sdfs", key];
    };
    [cache objectForKey:@"myKey"];
    
    
    self.obj = [[MyObject alloc] init];
    [self.obj _trimRecursively];
    
    NSString *cacheFolder = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *path = [cacheFolder stringByAppendingPathComponent:@"123"];
    
    id result = [[YYKVStorage alloc] initWithPath:path type:YYKVStorageTypeFile];
    NSLog(@"%@", result);
//    NSMutableDictionary *mutDic = [[NSMutableDictionary alloc] init];
//    MyObject *obj = [[MyObject alloc] init];
//    obj.name = @"na";
//    [mutDic setObject:obj forKey:@"key"];
//    __weak MyObject *obj = [[MyObject alloc] init];
    
//    NSDictionary *dict = [[NSDictionary alloc] initWithDictionary:@{@"key":@"value"}];
//    NSMutableDictionary *mutDict = [dict mutableCopy];
//    NSLog(@"%p", dict);
//    NSLog(@"%p", mutDict);
//    dict = [[NSDictionary alloc] initWithDictionary:@{@"key1":@"value2"}];
//    NSLog(@"%p", dict);
//    NSLog(@"%p", mutDict);
    
    
//    NSCache *cache;
//    NSDictionary *dict;
//    NSMutableSet *set;
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
//        [Benchmark benchmark];
    });
    
//    for (int i = 0; i < 10000; i++) {
//        [self _trimRecursively];
//    }
//    YYCache *cache = [[YYCache alloc] initWithName:@"nanana"];
//    __weak typeof(cache) _cache = cache;
//    [cache setObject:@"1" forKey:@"key" withBlock:^{
//    }];
//    NSLog(@"%@", _cache.diskCache.path);
//
    
    
//    NSMutableString *str = [[NSMutableString alloc] initWithString:@"123"];
//    YYMemoryCache *cache = [[YYMemoryCache alloc] init];
//    [cache setObject:str forKey:@"key"];
//    NSLog(@"1--%@", [cache objectForKey:@"key"]);
//    [str appendString:@"4"];
//    NSLog(@"1--%@", [cache objectForKey:@"key"]);
//    for (int i = 0; i < 100; i++) {
//        [cache setObject:@(i) forKey:@(i)];
//    }
//    [cache removeObjectForKey:@(1)];
//    NSLog(@"%lu", (unsigned long)cache.totalCount);
//
//    cache.didReceiveMemoryWarningBlock = ^(YYMemoryCache * _Nonnull cache) {
//        NSLog(@"%lu", (unsigned long)cache.totalCount);
//    };
    
}



@end
