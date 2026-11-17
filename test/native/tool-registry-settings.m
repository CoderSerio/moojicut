#import <AppKit/AppKit.h>
#import "native/macos/preferences/MCToolRegistryStore.h"
#import "native/macos/preferences/MCPluginManagementController.h"
#import "native/macos/preferences/MCPreferencesController.h"
#import "plugins/feature/pin/macos/MCPinnedImageController.h"
#include "moonbit.h"

NSNotificationName const MCUpdateStateDidChangeNotification = @"MCUpdateStateDidChangeNotification";
@interface MCPreferencesController (MCToolSettingsTest)
- (void)buildWindow;
@end
@interface MCTestToolDrag : NSObject
@property id draggingSource;
@property NSPasteboard *draggingPasteboard;
@end
@implementation MCTestToolDrag
@end

#define CHECK(c, message) do { if (!(c)) { fprintf(stderr, "FAIL tool settings: %s\n", message); passed = NO; } } while (0)
static NSView *findView(NSView *view, NSString *identifier) {
    if ([view.identifier isEqual:identifier]) return view;
    for (NSView *child in view.subviews) {
        NSView *found = findView(child, identifier);
        if (found) return found;
    }
    return nil;
}
static NSArray *ids(MCToolRegistryStore *store) {
    return [[store toolsForGroup:@"screenshot"] valueForKey:@"id"];
}
static NSDictionary *toolWithID(MCToolRegistryStore *store, NSString *identifier) {
    for (NSDictionary *tool in [store toolsForGroup:@"screenshot"])
        if ([tool[@"id"] isEqual:identifier]) return tool;
    return nil;
}
static NSButton *toggleFor(NSTableView *table, NSInteger row) {
    return (NSButton *)[table.delegate tableView:table viewForTableColumn:table.tableColumns[1] row:row];
}
static NSInteger rowForTool(NSTableView *table, NSString *identifier) {
    for (NSInteger row = 0; row < table.numberOfRows; row++)
        if ([toggleFor(table, row).identifier isEqual:identifier]) return row;
    return -1;
}

int main(void) {
    @autoreleasepool {
        moonbit_init();
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        BOOL passed = YES;
        NSString *domain = [@"dev.moojicut.tool-settings-test." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:domain];
        NSString *key = @"builtinToolLayoutV1";
        NSString *rectangle = @"builtin.image.rectangle", *arrow = @"builtin.image.arrow";
        NSString *text = @"builtin.image.text", *cover = @"builtin.image.cover", *pin = @"builtin.image.pin";
        NSString *ocr = @"builtin.capture.ocr", *translate = @"builtin.capture.translate", *scroll = @"builtin.capture.scroll", *numbered = @"builtin.image.numberedRectangle";
        MCToolRegistryStore *store = [[MCToolRegistryStore alloc] initWithDefaults:defaults];
        __block NSUInteger prepared = 0, applied = 0, notified = 0;
        __block BOOL veto = NO, nestedRejected = NO;
        __weak MCToolRegistryStore *weakStore = store;
        store.prepareChange = ^BOOL(__unused NSDictionary *candidate, NSError **error) {
            prepared++;
            if (veto && error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey:@"请完成输入"}];
            return !veto;
        };
        store.applyChange = ^(__unused NSDictionary *candidate) {
            applied++;
            nestedRejected = ![weakStore setTool:arrow enabled:NO error:NULL];
        };
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:MCToolRegistryDidChangeNotification object:store queue:nil
            usingBlock:^(__unused NSNotification *note) { notified++; }];
        MCPreferencesController *preferences = nil;
        MCPluginManagementController *controller = nil;
        @try {
            CHECK(([ids(store) isEqual:@[rectangle, arrow, text, cover, pin, ocr, translate, scroll, numbered]] && !store.loadError), "first launch exposes built-in tools and the pin action in default order");
            CHECK([defaults objectForKey:key] == nil, "opening settings does not write defaults");
            CHECK(![toolWithID(store,scroll)[@"enabled"] boolValue] && ![toolWithID(store,numbered)[@"enabled"] boolValue] &&
                  [toolWithID(store,pin)[@"slot"] isEqual:@"finish"] && [toolWithID(store,ocr)[@"slot"] isEqual:@"tools"] &&
                  [toolWithID(store,translate)[@"command"] isEqual:@"translate"] && [toolWithID(store,numbered)[@"interaction"] isEqual:@"dragRect"],
                  "settings consume the actual extension defaults, toolbar slots and generic command descriptors");
            CHECK([store toolsForGroup:@"recording"].count == 0 && [store toolsForGroup:@"videoEditing"].count == 0,
                  "unintegrated groups remain empty");
            NSError *error = nil;
            CHECK([store moveTool:text inGroup:@"screenshot" beforeTool:rectangle error:&error], "moving by stable ID succeeds");
            CHECK(([ids(store) isEqual:@[text, rectangle, arrow, cover, pin, ocr, translate, scroll, numbered]]), "move preserves the other tools' relative order");
            CHECK(nestedRejected && prepared == 1 && applied == 1 && notified == 1, "publication is synchronous and rejects reentrant changes");
            CHECK([store setTool:cover enabled:NO error:&error], "disable persists");
            MCToolRegistryStore *reopened = [[MCToolRegistryStore alloc] initWithDefaults:defaults];
            CHECK([ids(reopened) isEqual:ids(store)] && ![toolWithID(reopened, cover)[@"enabled"] boolValue],
                  "reopening preserves enabled state and order");
            NSDictionary *before = store.snapshot, *saved = [defaults dictionaryForKey:key];
            NSUInteger count = notified;
            veto = YES;
            CHECK(![store setTool:text enabled:NO error:&error] && error != nil, "active editor can veto a disable");
            CHECK([store.snapshot isEqual:before] && [[defaults dictionaryForKey:key] isEqual:saved] && notified == count,
                  "veto preserves the snapshot, saved settings and notification state");
            veto = NO;
            CHECK(![store moveTool:text inGroup:@"recording" beforeTool:nil error:&error] && notified == count,
                  "tools cannot move across host surfaces");

            preferences = [[MCPreferencesController alloc] initWithDefaults:defaults coreVersion:@"test" diagnostics:@{}];
            preferences.toolRegistryStore = store;
            [preferences buildWindow]; [preferences selectPage:@"plugins"];
            [preferences.window.contentView layoutSubtreeIfNeeded];
            NSTableView *table = (NSTableView *)findView(preferences.window.contentView, @"plugin-management-table");
            NSSegmentedControl *groups = (NSSegmentedControl *)findView(preferences.window.contentView, @"plugin-management-groups");
            NSButton *up = (NSButton *)findView(preferences.window.contentView, @"plugin-tool-move-up");
            NSButton *down = (NSButton *)findView(preferences.window.contentView, @"plugin-tool-move-down");
            NSButton *import = (NSButton *)findView(preferences.window.contentView, @"plugin-import");
            CHECK(table && table.numberOfRows == 9 && groups.segmentCount == 3 && !preferences.window.visible,
                  "real preferences exposes three categories and one tool list in a hidden fixture");
            CHECK(import && !import.enabled && [import.toolTip containsString:@"尚未初始化"], "import stays unavailable until the plugin service is attached");
            [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            CHECK(!up.enabled && down.enabled, "first row only moves down");
            [down performClick:nil];
            CHECK(([ids(store) isEqual:@[rectangle, text, arrow, cover, pin, ocr, translate, scroll, numbered]] && table.selectedRow == 1), "down button saves order and follows stable selection");
            [up performClick:nil];
            CHECK([ids(store).firstObject isEqual:text] && table.selectedRow == 0, "up button updates the same order contract");
            veto = YES;
            NSButton *toggle = toggleFor(table, 0);
            [toggle performClick:nil];
            CHECK(toggleFor(table, 0).state == NSControlStateValueOn && [[store toolsForGroup:@"screenshot"][0][@"enabled"] boolValue],
                  "failed tool disable restores its visible switch");
            veto = NO;
            [toggleFor(table, 0) performClick:nil];
            CHECK(toggleFor(table, 0).state == NSControlStateValueOff, "successful row switch is reflected in the table");
            [toggleFor(table, 0) performClick:nil];

            MCTestToolDrag *drag = [MCTestToolDrag new];
            drag.draggingSource = table; drag.draggingPasteboard = [NSPasteboard pasteboardWithUniqueName];
            id<NSPasteboardWriting> writer = [table.dataSource tableView:table pasteboardWriterForRow:0];
            [drag.draggingPasteboard writeObjects:@[writer]];
            id<NSDraggingInfo> info = (id<NSDraggingInfo>)drag;
            NSInteger finishRow = rowForTool(table, pin);
            CHECK(finishRow == table.numberOfRows - 1 && finishRow > 0,
                  "settings display tools before the separate finish slot regardless of registry storage order");
            before = store.snapshot; saved = [defaults dictionaryForKey:key]; count = notified;
            CHECK([table.dataSource tableView:table validateDrop:info proposedRow:table.numberOfRows proposedDropOperation:NSTableViewDropAbove] == NSDragOperationNone &&
                  ![table.dataSource tableView:table acceptDrop:info row:table.numberOfRows dropOperation:NSTableViewDropAbove] &&
                  [store.snapshot isEqual:before] && [[defaults dictionaryForKey:key] isEqual:saved] && notified == count,
                  "dragging a tool beyond the finish slot is rejected without changing saved or live state");
            CHECK([table.dataSource tableView:table validateDrop:info proposedRow:finishRow proposedDropOperation:NSTableViewDropAbove] == NSDragOperationMove,
                  "a tool can be dropped at the end of its own slot directly above the first finish row");
            CHECK([table.dataSource tableView:table acceptDrop:info row:finishRow dropOperation:NSTableViewDropAbove] &&
                  rowForTool(table, text) == finishRow - 1 && rowForTool(table, pin) == finishRow,
                  "dropping at the tools boundary appends within tools and leaves finish actions in place");
            reopened = [[MCToolRegistryStore alloc] initWithDefaults:defaults];
            CHECK([ids(reopened) isEqual:ids(store)] && [ids(store).lastObject isEqual:text],
                  "the slot-end drag persists the same stable-ID order that the settings display");
            [table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)rowForTool(table, text)] byExtendingSelection:NO];
            CHECK(up.enabled && !down.enabled, "the last tool cannot move into finish through the arrow buttons");
            [drag.draggingPasteboard clearContents];
            writer = [table.dataSource tableView:table pasteboardWriterForRow:rowForTool(table, pin)];
            [drag.draggingPasteboard writeObjects:@[writer]];
            CHECK([table.dataSource tableView:table validateDrop:info proposedRow:0 proposedDropOperation:NSTableViewDropAbove] == NSDragOperationNone &&
                  ![table.dataSource tableView:table acceptDrop:info row:0 dropOperation:NSTableViewDropAbove],
                  "finish actions cannot be dragged into tools");
            drag.draggingSource = [NSTableView new];
            CHECK([table.dataSource tableView:table validateDrop:info proposedRow:0 proposedDropOperation:NSTableViewDropAbove] == NSDragOperationNone,
                  "foreign table drag cannot mutate tools");
            [drag.draggingPasteboard releaseGlobally];
            for (NSInteger index = 1; index < 3; index++) {
                groups.selectedSegment = index; [groups sendAction:groups.action to:groups.target];
                CHECK(table.numberOfRows == 0 && !up.enabled && !down.enabled, "empty groups expose no fake interactive actions");
            }
            groups.selectedSegment = 0; [groups sendAction:groups.action to:groups.target];
            [preferences setPinningEnabled:NO];
            CHECK(![toolWithID(store, pin)[@"enabled"] boolValue] && ![defaults boolForKey:MCPinFeatureEnabledDefaultsKey],
                  "legacy general checkbox uses the same registry gate and persisted preference");
            NSInteger pinRow = rowForTool(table, pin);
            [toggleFor(table, pinRow) performClick:nil];
            CHECK(preferences.pinningEnabled && [(NSButton *)[preferences valueForKey:@"pinningCheckbox"] state] == NSControlStateValueOn &&
                  [defaults boolForKey:MCPinFeatureEnabledDefaultsKey], "management switch also updates the general checkbox and shared gate");
            NSInteger numberedRow = rowForTool(table, numbered);
            [toggleFor(table,numberedRow) performClick:nil];
            CHECK([toolWithID(store,numbered)[@"enabled"] boolValue] &&
                  [toolWithID(store,numbered)[@"command"] isEqual:@"capture.numberedRectangle"],
                  "the new declared tool is enabled by the same settings row without a native tool-specific branch");
            [toggleFor(table,numberedRow) performClick:nil];
            NSString *previewPath = NSProcessInfo.processInfo.environment[@"MOOJICUT_TOOL_SETTINGS_PREVIEW"];
            if (previewPath.length) {
                NSView *content = preferences.window.contentView;
                [content layoutSubtreeIfNeeded]; [content displayIfNeeded];
                NSBitmapImageRep *preview = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
                [content cacheDisplayInRect:content.bounds toBitmapImageRep:preview];
                CHECK([[preview representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:previewPath atomically:YES],
                      "settings preview renders without opening the window");
            }
            [preferences.window close]; preferences = nil;
            reopened = [[MCToolRegistryStore alloc] initWithDefaults:defaults];
            controller = [[MCPluginManagementController alloc] initWithStore:reopened];
            CHECK(((NSTableView *)findView(controller.view, @"plugin-management-table")).numberOfRows == 9 &&
                  [ids(reopened) isEqual:ids(store)], "management view can reopen after its previous observer was removed");
            [controller invalidate]; controller = nil;

            // A new layout is authoritative over the legacy key. Old layouts
            // without an explicit pin entry inherit its disabled preference.
            [defaults setBool:NO forKey:MCPinFeatureEnabledDefaultsKey];
            reopened = [[MCToolRegistryStore alloc] initWithDefaults:defaults];
            CHECK([toolWithID(reopened, pin)[@"enabled"] boolValue], "explicit registry pin state wins over stale legacy defaults");
            NSMutableDictionary *oldLayout = [store.snapshot[@"layout"] mutableCopy];
            NSMutableDictionary *oldGroups = [oldLayout[@"groups"] mutableCopy];
            oldGroups[@"screenshot"] = [oldGroups[@"screenshot"] filteredArrayUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(NSDictionary *entry, __unused NSDictionary *bindings) {
                    return ![entry[@"id"] isEqual:pin];
                }]];
            oldLayout[@"groups"] = oldGroups; [defaults setObject:oldLayout forKey:key];
            reopened = [[MCToolRegistryStore alloc] initWithDefaults:defaults];
            CHECK(![toolWithID(reopened, pin)[@"enabled"] boolValue] && [[defaults dictionaryForKey:key] isEqual:oldLayout],
                  "old disabled pin gate migrates in memory without a startup write");
            CHECK([reopened setTool:pin enabled:YES error:&error] && [defaults boolForKey:MCPinFeatureEnabledDefaultsKey],
                  "first explicit edit saves the migrated layout and shared gate");

            [defaults setObject:@{@"version":@999} forKey:key];
            reopened = [[MCToolRegistryStore alloc] initWithDefaults:defaults];
            CHECK(reopened.loadError && [reopened toolsForGroup:@"screenshot"].count == 9 &&
                  [[defaults dictionaryForKey:key][@"version"] integerValue] == 999,
                  "corrupt preferences recover in memory without overwriting the original");
            CHECK([reopened setTool:text enabled:NO error:&error] && !reopened.loadError &&
                  [[defaults dictionaryForKey:key][@"version"] integerValue] == 1, "explicit user edit replaces invalid saved data");
        } @finally {
            [controller invalidate]; [preferences.window close];
            [NSNotificationCenter.defaultCenter removeObserver:observer];
            [defaults removePersistentDomainForName:domain];
        }
        puts(passed ? "PASS tool settings: persistence, transaction veto, reentrancy, native list, switches, reorder delegates and reopen" : "FAIL tool settings");
        return passed ? 0 : 1;
    }
}
