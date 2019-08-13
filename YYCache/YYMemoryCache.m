//
//  YYMemoryCache.m
//  YYCache <https://github.com/ibireme/YYCache>
//
//  Created by ibireme on 15/2/7.
//  Copyright (c) 2015 ibireme.
//
//  This source code is licensed under the MIT-style license found in the
//  LICENSE file in the root directory of this source tree.
//

#import "YYMemoryCache.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <pthread.h>

// static修饰可以在多个文件中定义
// inline内联函数, 提高效率, 在调用的时候是在调用出直接替换, 而普通的函数需要开辟栈空间(push pop操作)
static inline dispatch_queue_t YYMemoryCacheGetReleaseQueue() {
    return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0);
}

/**
 A node in linked map.
 Typically, you should not use this class directly.
 */
@interface _YYLinkedMapNode : NSObject {
    @package
    __unsafe_unretained _YYLinkedMapNode *_prev; // retained by dic
    __unsafe_unretained _YYLinkedMapNode *_next; // retained by dic
    id _key; // key
    id _value; // value
    NSUInteger _cost; // 结点的开销, 在内存中占用的字节数
    NSTimeInterval _time; // 操作结点的时间
}
@end

@implementation _YYLinkedMapNode

@end


/**
 可以理解为双向链表? 有头指针和尾指针
 A linked map used by YYMemoryCache.
 It's not thread-safe and does not validate the parameters.
 
 Typically, you should not use this class directly.
 */
@interface _YYLinkedMap : NSObject {
    @package
    CFMutableDictionaryRef _dic; // do not set object directly key: key, value: Node结点
    NSUInteger _totalCost; // 总开销
    NSUInteger _totalCount; // 缓存数量
    _YYLinkedMapNode *_head; // MRU, do not change it directly 头结点
    _YYLinkedMapNode *_tail; // LRU, do not change it directly 尾结点
    BOOL _releaseOnMainThread; // 是否在主线程release结点
    BOOL _releaseAsynchronously; // 是否异步release结点
}

/// Insert a node at head and update the total cost.
/// Node and node.key should not be nil.
/// 添加头结点
- (void)insertNodeAtHead:(_YYLinkedMapNode *)node;

/// Bring a inner node to header.
/// Node should already inside the dic.
/// 将链表中的某个存在的结点移动到头部
- (void)bringNodeToHead:(_YYLinkedMapNode *)node;

/// Remove a inner node and update the total cost.
/// Node should already inside the dic.
/// 移除结点
- (void)removeNode:(_YYLinkedMapNode *)node;

/// Remove tail node if exist.
/// 移除尾结点
- (_YYLinkedMapNode *)removeTailNode;

/// Remove all node in background queue.
/// 清空, 通过异步和主线程做判断
- (void)removeAll;

@end

@implementation _YYLinkedMap

- (instancetype)init {
    self = [super init];
    // _dic需要手动管理内存
    _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    _releaseOnMainThread = NO;
    _releaseAsynchronously = YES;
    return self;
}

- (void)dealloc {
    CFRelease(_dic);
}

- (void)insertNodeAtHead:(_YYLinkedMapNode *)node {
    // 将结点node保存在_dic中
    CFDictionarySetValue(_dic, (__bridge const void *)(node->_key), (__bridge const void *)(node));
    // 根据结点的cost开销修改map记录的总开销数
    _totalCost += node->_cost;
    // 记录缓存个数
    _totalCount++;
    if (_head) {
        // 将结点node设置为头结点
        node->_next = _head;
        _head->_prev = node;
        _head = node;
    } else {
        // 如果头结点为nil, 说明链表为空, 添加的结点node就是头结点 并且还是尾结点
        _head = _tail = node;
    }
}

- (void)bringNodeToHead:(_YYLinkedMapNode *)node {
    // 如果只有一个结点, 说明不需要移动
    if (_head == node) return;
    
    if (_tail == node) {
        // 如果node是尾结点, 重新设置尾结点
        _tail = node->_prev;
        _tail->_next = nil;
    } else {
        // node既不是头结点又不是尾结点, 相当于删除结点node
        node->_next->_prev = node->_prev;
        node->_prev->_next = node->_next;
    }
    // 将node设置为头结点
    node->_next = _head;
    node->_prev = nil;
    _head->_prev = node;
    _head = node;
}

- (void)removeNode:(_YYLinkedMapNode *)node {
    // 将结点node从字典_dic中移除, 注意这是node的引用计数减1
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(node->_key));
    // 修改总开销
    _totalCost -= node->_cost;
    // 缓存数量减1
    _totalCount--;
    // 修改node结点的下一个结点prev指向
    if (node->_next) node->_next->_prev = node->_prev;
    // 修改node结点的上一个结点的next指向
    if (node->_prev) node->_prev->_next = node->_next;
    // 如果node是头结点, 将头结点设置为node的下一个结点
    if (_head == node) _head = node->_next;
    // 如果node是尾结点, 将尾结点设置为node的上一个结点
    if (_tail == node) _tail = node->_prev;
}

/// 移除尾结点
/// 1. 从字典中移除, 因为字典有强引用
/// 2. 从尾结点移除, 尾结点的上一个结点对结点有引用
- (_YYLinkedMapNode *)removeTailNode {
    if (!_tail) return nil;
    // 获取尾结点
    _YYLinkedMapNode *tail = _tail;
    // 将尾结点从字典中移除, 因为字典有强引用
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(_tail->_key));
    _totalCost -= _tail->_cost;
    _totalCount--;
    if (_head == _tail) {
        // 如果头结点=尾结点, 移除之后链表为空
        _head = _tail = nil;
    } else {
        // 否者重置尾结点
        _tail = _tail->_prev;
        _tail->_next = nil;
    }
    return tail;
}

- (void)removeAll {
    // 清空信息
    _totalCost = 0;
    _totalCount = 0;
    _head = nil;
    _tail = nil;
    if (CFDictionaryGetCount(_dic) > 0) {
        // 相当于对_dic进行了一次mutableCopy, 由于_dic是不可变, 所以holder和_dic执行了同一块内存空间(堆空间)
        CFMutableDictionaryRef holder = _dic;
        // 重新在堆空间申请内存, _dic执行新分配的内存(之前堆空间的内存地址保存在holder中)
        _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        // 如果需要异步执行, 不阻塞当前线程
        if (_releaseAsynchronously) {
            dispatch_queue_t queue = _releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                CFRelease(holder); // hold and release in specified queue
            });
        } else if (_releaseOnMainThread && !pthread_main_np()) {
            // 主线程执行
            dispatch_async(dispatch_get_main_queue(), ^{
                CFRelease(holder); // hold and release in specified queue
            });
        } else {
            // 主线程执行
            CFRelease(holder);
        }
    }
}

@end



@implementation YYMemoryCache {
    pthread_mutex_t _lock; // 互斥锁
    _YYLinkedMap *_lru; // least recent used
    dispatch_queue_t _queue; // 串行队列
}

// 递归查询需要移除的内容, 相当于做了一个定时器啊..
- (void)_trimRecursively {
    // 使用weakself, block不会对self进行强引用
    __weak typeof(self) _self = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_autoTrimInterval * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        // __strong修饰, 防止self被提前销毁
        __strong typeof(_self) self = _self;
        if (!self) return;
        [self _trimInBackground];
        [self _trimRecursively];
    });
}

- (void)_trimInBackground {
    // 在串行队列中执行的清除操作, 这里为什么不用weakself呢? 因为gcd的block对self有强引用, 但是当block执行完成以后, self就会被释放.
    // 为什么是串行队列? 猜想: 串行队列中的任务会等待上个任务执行完成以后才执行, 是想按照cost->count->age的顺序去清除缓存
    dispatch_async(_queue, ^{
        [self _trimToCost:self->_costLimit];
        [self _trimToCount:self->_countLimit];
        [self _trimToAge:self->_ageLimit];
    });
}

- (void)_trimToCost:(NSUInteger)costLimit {
    BOOL finish = NO;
    // 避免多线程访问出现数据错乱, 所以选择加锁
    pthread_mutex_lock(&_lock);
    if (costLimit == 0) {
        // 如果内存开销设置为0, 表示清空缓存
        [_lru removeAll];
        finish = YES;
    } else if (_lru->_totalCost <= costLimit) {
        // 如果当前缓存的开销小于指定限制开销, 不需要清理
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    // 创建一个数组, 数组中存放的是结点, 为了在指定的线程 异步或者同步release
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        // 尝试加锁, 如果成功就为0
        if (pthread_mutex_trylock(&_lock) == 0) {
            // 将需要移除的结点添加到数组中
            if (_lru->_totalCost > costLimit) {
                // 这里node虽然从dic字典和双向链表中移除了, 但是又加入了数组中, 所以这里node并不会被销毁
                _YYLinkedMapNode *node = [_lru removeTailNode];
                if (node) [holder addObject:node];
            } else {
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            // 为了防止争夺资源, sleep10ms
            usleep(10 * 1000); //10 ms
        }
    }
    // holder中保存了需要release的node结点
    if (holder.count) {
        // 根据配置选择是否在主线程中release结点资源
        // YYMemoryCacheGetReleaseQueue()是内联函数, 创建的全局并发队列
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        // 在队列中移除
        dispatch_async(queue, ^{
            // 这里我的理解是 block会对holder强引用, 当block执行完成以后holder的引用计数减1
            [holder count]; // release in queue
        });
    }
    // 因为block中对holder有强引用, 所以出了}以后, holder的引用计数减1, 不会被销毁, 而是在block中销毁(实现在指定的队列中销毁).
}

- (void)_trimToCount:(NSUInteger)countLimit {
    BOOL finish = NO;
    pthread_mutex_lock(&_lock);
    if (countLimit == 0) {
        [_lru removeAll];
        finish = YES;
    } else if (_lru->_totalCount <= countLimit) {
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_totalCount > countLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode];
                if (node) [holder addObject:node];
            } else {
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); //10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}

- (void)_trimToAge:(NSTimeInterval)ageLimit {
    BOOL finish = NO;
    NSTimeInterval now = CACurrentMediaTime();
    pthread_mutex_lock(&_lock);
    if (ageLimit <= 0) {
        [_lru removeAll];
        finish = YES;
    } else if (!_lru->_tail || (now - _lru->_tail->_time) <= ageLimit) {
        finish = YES;
    }
    pthread_mutex_unlock(&_lock);
    if (finish) return;
    
    NSMutableArray *holder = [NSMutableArray new];
    while (!finish) {
        if (pthread_mutex_trylock(&_lock) == 0) {
            if (_lru->_tail && (now - _lru->_tail->_time) > ageLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode];
                if (node) [holder addObject:node];
            } else {
                finish = YES;
            }
            pthread_mutex_unlock(&_lock);
        } else {
            usleep(10 * 1000); //10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        dispatch_async(queue, ^{
            [holder count]; // release in queue
        });
    }
}

- (void)_appDidReceiveMemoryWarningNotification {
    if (self.didReceiveMemoryWarningBlock) {
        self.didReceiveMemoryWarningBlock(self);
    }
    if (self.shouldRemoveAllObjectsOnMemoryWarning) {
        [self removeAllObjects];
    }
}

- (void)_appDidEnterBackgroundNotification {
    if (self.didEnterBackgroundBlock) {
        self.didEnterBackgroundBlock(self);
    }
    if (self.shouldRemoveAllObjectsWhenEnteringBackground) {
        [self removeAllObjects];
    }
}

#pragma mark - public

- (instancetype)init {
    self = super.init;
    pthread_mutex_init(&_lock, NULL);
    _lru = [_YYLinkedMap new];
    _queue = dispatch_queue_create("com.ibireme.cache.memory", DISPATCH_QUEUE_SERIAL);
    
    _countLimit = NSUIntegerMax;
    _costLimit = NSUIntegerMax;
    _ageLimit = DBL_MAX;
    _autoTrimInterval = 5.0;
    _shouldRemoveAllObjectsOnMemoryWarning = YES;
    _shouldRemoveAllObjectsWhenEnteringBackground = YES;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidReceiveMemoryWarningNotification) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_appDidEnterBackgroundNotification) name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    // 自动清除功能
    [self _trimRecursively];
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidEnterBackgroundNotification object:nil];
    [_lru removeAll];
    pthread_mutex_destroy(&_lock);
}

- (NSUInteger)totalCount {
    pthread_mutex_lock(&_lock);
    NSUInteger count = _lru->_totalCount;
    pthread_mutex_unlock(&_lock);
    return count;
}

- (NSUInteger)totalCost {
    pthread_mutex_lock(&_lock);
    NSUInteger totalCost = _lru->_totalCost;
    pthread_mutex_unlock(&_lock);
    return totalCost;
}

- (BOOL)releaseOnMainThread {
    pthread_mutex_lock(&_lock);
    BOOL releaseOnMainThread = _lru->_releaseOnMainThread;
    pthread_mutex_unlock(&_lock);
    return releaseOnMainThread;
}

- (void)setReleaseOnMainThread:(BOOL)releaseOnMainThread {
    pthread_mutex_lock(&_lock);
    _lru->_releaseOnMainThread = releaseOnMainThread;
    pthread_mutex_unlock(&_lock);
}

- (BOOL)releaseAsynchronously {
    pthread_mutex_lock(&_lock);
    BOOL releaseAsynchronously = _lru->_releaseAsynchronously;
    pthread_mutex_unlock(&_lock);
    return releaseAsynchronously;
}

- (void)setReleaseAsynchronously:(BOOL)releaseAsynchronously {
    pthread_mutex_lock(&_lock);
    _lru->_releaseAsynchronously = releaseAsynchronously;
    pthread_mutex_unlock(&_lock);
}

- (BOOL)containsObjectForKey:(id)key {
    if (!key) return NO;
    // 因为需要操作map中的数据, 加锁
    pthread_mutex_lock(&_lock);
    BOOL contains = CFDictionaryContainsKey(_lru->_dic, (__bridge const void *)(key));
    pthread_mutex_unlock(&_lock);
    return contains;
}

- (id)objectForKey:(id)key {
    if (!key) return nil;
    pthread_mutex_lock(&_lock);
    // 先从字典中获取node
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    if (node) {
        // 因为操作了node, 所以需要将node的时间修改成当前时间
        node->_time = CACurrentMediaTime();
        // 操作了结点, 将结点设置为头结点.
        [_lru bringNodeToHead:node];
    }
    pthread_mutex_unlock(&_lock);
    return node ? node->_value : nil;
}

- (void)setObject:(id)object forKey:(id)key {
    [self setObject:object forKey:key withCost:0];
}

- (void)setObject:(id)object forKey:(id)key withCost:(NSUInteger)cost {
    if (!key) return;
    // 如果object为nil, 说明是移除key
    if (!object) {
        [self removeObjectForKey:key];
        return;
    }
    pthread_mutex_lock(&_lock);
    // 将node存储在字典中
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    // 获取当前时间, 用于设置node的操作时间
    NSTimeInterval now = CACurrentMediaTime();
    if (node) {
        // 如果node已经存在缓存中, 需要将node的time修改, 并且将node添加到表头
        _lru->_totalCost -= node->_cost;
        _lru->_totalCost += cost;
        node->_cost = cost;
        node->_time = now;
        node->_value = object;
        [_lru bringNodeToHead:node];
    } else {
        // 如果node不存在, 需要创建node, 并且添加到表头
        node = [_YYLinkedMapNode new];
        node->_cost = cost;
        node->_time = now;
        node->_key = key;
        node->_value = object;
        [_lru insertNodeAtHead:node];
    }
    // 添加完成以后, 因为_totalCost增加, 需要检查总开销是否超过了设定的标准_costLimit
    if (_lru->_totalCost > _costLimit) {
        // 在串行队列中异步清除缓存
        dispatch_async(_queue, ^{
            [self trimToCost:_costLimit];
        });
    }
    // 添加完成以后, 因为_totalCount增加, 需要检查_totalCount是否大于_countLimit
    if (_lru->_totalCount > _countLimit) {
        // 因为每次只增加一个node, 所以只需要移除最后一个尾结点即可
        _YYLinkedMapNode *node = [_lru removeTailNode];
        if (_lru->_releaseAsynchronously) {
            dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                [node class]; //hold and release in queue
            });
        } else if (_lru->_releaseOnMainThread && !pthread_main_np()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [node class]; //hold and release in queue
            });
        }
    }
    pthread_mutex_unlock(&_lock);
}

- (void)removeObjectForKey:(id)key {
    if (!key) return;
    pthread_mutex_lock(&_lock);
    // 获取需要移除的node
    _YYLinkedMapNode *node = CFDictionaryGetValue(_lru->_dic, (__bridge const void *)(key));
    if (node) {
        [_lru removeNode:node];
        if (_lru->_releaseAsynchronously) {
            dispatch_queue_t queue = _lru->_releaseOnMainThread ? dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                [node class]; //hold and release in queue
            });
        } else if (_lru->_releaseOnMainThread && !pthread_main_np()) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [node class]; //hold and release in queue
            });
        }
    }
    pthread_mutex_unlock(&_lock);
}

- (void)removeAllObjects {
    pthread_mutex_lock(&_lock);
    [_lru removeAll];
    pthread_mutex_unlock(&_lock);
}

- (void)trimToCount:(NSUInteger)count {
    if (count == 0) {
        [self removeAllObjects];
        return;
    }
    [self _trimToCount:count];
}

- (void)trimToCost:(NSUInteger)cost {
    [self _trimToCost:cost];
}

- (void)trimToAge:(NSTimeInterval)age {
    [self _trimToAge:age];
}

- (NSString *)description {
    if (_name) return [NSString stringWithFormat:@"<%@: %p> (%@)", self.class, self, _name];
    else return [NSString stringWithFormat:@"<%@: %p>", self.class, self];
}

@end
