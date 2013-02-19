//
//  CoreDataModel.h
//  CoreDataModel
//
//  Created by Nicolas Bouilleaud on 15/05/11.
//  Copyright (c) 2011-2013 Nicolas Bouilleaud. All rights reserved.
//

#import <CoreData/CoreData.h>
#import "NSManagedObjectContext+ValidateDeleteAndSave.h"
#import "NSError+MultipleErrorsCombined.h"

// Core Data Standard Machinery.
// Meant to be Subclassed in your app for each datamodel.
@interface CoreDataModel : NSObject

// Create a manager with a modelName (name of the mom/momd file in the App Bundle)
// and a storePath (the store file path)
- (id) initWithModelName:(NSString*)modelName_ storePath:(NSString*)storePath_;
- (id) init; // Uses the class name as the modelName and the filename, created in +defaultStoreDirectory.

+ (NSString *) defaultStoreDirectory; // used in -init. initial value is the Documents directory.
+ (void) setDefaultStoreDirectory:(NSString*)defaultStoreDirectory_;

// Returns wether the store is loaded.
//
// Store is lazy loaded the first time it's used (when mainContext or performUpdates:saveCompletion: is called.)
- (BOOL) isStoreLoaded;

- (void) storeDidLoad;// reimplement to perform specific tasks after loading the store.

// The main context, to be used on the main thread.
- (NSManagedObjectContext *) mainContext;

// Perform a batch of updates in the internal context, save it, merge the changes in the UI context, and notify when done.
// Uses the "ValidateDeleteAndSave" mechanism to save. If an object is invalid, it's deleted and saving is retried.
//
// The "updates" block may optionally return a debug dictionary, with keys the managedObjects and values debug information that will be logged
// if the object fails validation and is deleted
- (void) performUpdates:(void(^)(NSManagedObjectContext* updateContext))updates
         saveCompletion:(void(^)(NSNotification* contextDidSaveNotification))completion;

// Delete the store, the psc, and the moc. The receiver is effectively rendered useless.
- (void) erase;

@end

// reverse link to obtain the CoreDataModel from a moc, for example in the objects implementation.
@interface NSManagedObjectContext (AssociatedManager)
@property (nonatomic, retain, readonly) CoreDataModel * coreDataModel;
@end
