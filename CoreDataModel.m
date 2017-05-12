//
//  CoreDataModel.m
//	CoreDataModel
//
//  Created by Nicolas Bouilleaud on 15/05/11.
//  Copyright (c) 2011-2012 Nicolas Bouilleaud. All rights reserved.
//

#import "CoreDataModel.h"
#import "NSError+MultipleErrorsCombined.h"
#import "NSManagedObjectContext+ValidateDeleteAndSave.h"
#import <objc/runtime.h>

/****************************************************************************/
#pragma mark Private Methods

@interface CoreDataModel ()
@end

@interface NSManagedObjectContext (AssociatedManager_Private)
@property (nonatomic, retain, readwrite) CoreDataModel * coreDataModel;
@property (readwrite) NSString * storePath;
@end

/****************************************************************************/
#pragma mark -

@implementation CoreDataModel
{
    NSString * _modelName;
    NSManagedObjectModel * _mom;
    NSPersistentStoreCoordinator * _psc;
    NSManagedObjectContext *_mainContext;
    NSOperationQueue * _backgroundQueue;
}

/****************************************************************************/
#pragma mark Init

- (id)init
{
    NSString * className = NSStringFromClass(self.class);
    NSString * directory = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject];
    NSString * storePath = [directory stringByAppendingPathComponent:[className stringByAppendingPathExtension:@"coredata"]];
    return [self initWithModelName:className storePath:storePath];
}

- (id) initWithModelName:(NSString*)modelName_ storePath:(NSString*)storePath_
{
    self = [super init];
    if (self) {
        _storePath = storePath_;
        _modelName = modelName_;
    }
    return self;
}

/****************************************************************************/
#pragma mark Loading

static BOOL DebugForceInMemoryStores;

+ (BOOL)forceInMemoryStores
{
    return DebugForceInMemoryStores;
}

+(void)setForceInMemoryStores:(BOOL)value_
{
    DebugForceInMemoryStores = value_;
}

- (BOOL) isStoreLoaded
{
    return nil!=_mainContext;
}

- (void)storeDidLoad {}

- (void)loadStoreIfNeeded
{
    NSAssert(NSThread.currentThread == NSThread.mainThread, nil);
    
    if(nil==_mainContext)
    {
        // Create mom. Look for mom and momd variants.
        NSURL * momURL = [[NSBundle bundleForClass:self.class] URLForResource:_modelName withExtension:@"mom"];
        if(momURL==nil)
            momURL = [[NSBundle bundleForClass:self.class] URLForResource:_modelName withExtension:@"momd"];
		_mom = [[NSManagedObjectModel alloc] initWithContentsOfURL:momURL];
        
        // Create psc
		_psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:_mom];
		NSError *error = nil;
        
        if(self.storePath && !self.class.forceInMemoryStores)
        {
            // Add Persistent Store
            if (![_psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:self.storePath]
                                          options:nil error:&error])
            {
                if( error.code == NSPersistentStoreIncompatibleVersionHashError )
                {
                    // This happens a lot during development. Just dump the old store and create a new one.
                    NSLog(@"Incompatible data store. Trying to remove the existing db");
                    [NSFileManager.defaultManager removeItemAtPath:self.storePath error:NULL];
                    error = nil;
                                        
                    // Retry
                    [_psc addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:[NSURL fileURLWithPath:self.storePath]
                                             options:nil error:&error];
                }
                
                if (error)
                {
                    NSLog(@"Unresolved error when opening store %@, %@", error, [error userInfo]);
                    // shit.
                    abort();
                }
            }
        }
        else
        {
            // Create an inmemory store
            [_psc addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error];
            if (error)
            {
                NSLog(@"Unresolved error when creating memory store %@, %@", error, [error userInfo]);
                // shit.
                abort();
            }
        }
        
        // Create update queue
        _backgroundQueue = NSOperationQueue.new;
        _backgroundQueue.maxConcurrentOperationCount = 1;
        
        // Create main moc
        _mainContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];
        _mainContext.persistentStoreCoordinator = _psc;
        
        _mainContext.coreDataModel = self;
        
        [self storeDidLoad];
    }
}

- (NSManagedObjectContext *)mainContext
{
    [self loadStoreIfNeeded];
    return _mainContext;
}

/******************************************************************************/
#pragma mark -

- (void)erase
{
    [self loadStoreIfNeeded];
    NSURL * storeURL = [[[_psc persistentStores] lastObject] URL];
    [NSFileManager.defaultManager removeItemAtURL:storeURL error:NULL];
    _mainContext = nil;
    [_backgroundQueue cancelAllOperations];
    _backgroundQueue = nil;
    _psc = nil;
    _mom = nil;
}

/******************************************************************************/
#pragma mark -

- (NSManagedObjectContext *)newTemporaryContext
{
    NSManagedObjectContext * context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];
    context.persistentStoreCoordinator = _psc;
    context.coreDataModel = self;
    return context;
}

- (NSManagedObjectContext *)currentContext
{
    if([NSThread.currentThread isEqual:NSThread.mainThread]) {
        return self.mainContext;
    } else {
        if(![self isStoreLoaded]) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [self loadStoreIfNeeded];
            });
        }
        
        NSString * tlsKey = self.storePath;
        NSManagedObjectContext * context = [NSThread.currentThread threadDictionary][tlsKey];
        if(context==nil) {
            context = [self newTemporaryContext];
            [NSThread.currentThread threadDictionary][tlsKey] = context;
        }
        return context;
    }
}

- (void)performUpdates:(void(^)(NSManagedObjectContext* updateContext))updates
         saveCompletion:(void(^)(NSNotification* contextDidSaveNotification))completion
{
    [self loadStoreIfNeeded];
    
    // Perform the update in a background queue
    __block NSOperation * updateOperation = [NSBlockOperation blockOperationWithBlock:^
     {
         // Create the context
         NSManagedObjectContext * updateContext = [self newTemporaryContext];

         // Observe save notification to forward to the completion block in the main queue.
         __block id observation =
         [NSNotificationCenter.defaultCenter addObserverForName:NSManagedObjectContextDidSaveNotification
                                                           object:updateContext
                                                            queue:[NSOperationQueue mainQueue]
                                                       usingBlock:^(NSNotification *note)
          {
              [NSNotificationCenter.defaultCenter removeObserver:observation];

              // Check we're not cancelled
              if(updateOperation.isCancelled) return ;

              // Merge changes
              [_mainContext mergeChangesFromContextDidSaveNotification:note];

              // Call completion
              if(completion)
                  completion(note);
          }];
         
         // Call the update block
         updates(updateContext);
         
         // Check we're not cancelled
         if(updateOperation.isCancelled) return ;
         
         // Validate, Delete, Save
         NSArray * deletedObjects;
         NSError * finalSaveError;
         __unused BOOL didSave = [updateContext saveAndDeleteInvalidObjects:&deletedObjects finalSaveError:&finalSaveError];
                  
         // Do not handle save errors, we handle invalid objects and other errors are programmer errors.
         NSAssert(didSave || updateOperation.isCancelled,@"Failed to save :%@",finalSaveError);
     }];
                                     
    [_backgroundQueue addOperation:updateOperation];
}

@end

/****************************************************************************/
#pragma mark -

@implementation NSManagedObjectContext (AssociatedManager)
static char kCoreDataModel_associatedManagerKey;

- (void)setCoreDataModel:(CoreDataModel*)coreDataModel
{
    objc_setAssociatedObject(self, &kCoreDataModel_associatedManagerKey, coreDataModel, OBJC_ASSOCIATION_RETAIN);
}

- (CoreDataModel*)coreDataModel
{
    return objc_getAssociatedObject(self, &kCoreDataModel_associatedManagerKey);
}
@end


/****************************************************************************/
#pragma mark -

// Return the "same" object (same identifier) in another context.
@implementation NSManagedObject (ObjectInContext)
- (instancetype) objectInContext:(NSManagedObjectContext*)otherContext
{
    return [otherContext existingObjectWithID:self.objectID error:nil];
}
@end

