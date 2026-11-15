#import "MCPluginManagementController.h"
#import "MCToolRegistryStore.h"
#import "components/icons/macos/MCIcon.h"

static NSPasteboardType const MCToolRowPasteboardType = @"dev.moojicut.tool-row";

@interface MCPluginManagementController () <NSTableViewDataSource, NSTableViewDelegate>
@property NSSegmentedControl *groups;
@property NSTableView *table;
@property NSScrollView *scroll;
@property NSTextField *emptyLabel;
@property NSTextField *feedback;
@property NSButton *moveUpButton;
@property NSButton *moveDownButton;
@property NSArray<NSDictionary *> *rows;
@property (nullable) NSString *draggedIdentifier;
@property (nullable) NSString *draggedGroup;
@end

@implementation MCPluginManagementController
- (instancetype)initWithStore:(MCToolRegistryStore *)store {
    if ((self = [super initWithNibName:nil bundle:nil])) self.toolRegistryStore = store;
    return self;
}
- (void)setToolRegistryStore:(MCToolRegistryStore *)store {
    if (_toolRegistryStore == store) return;
    if (_toolRegistryStore) [NSNotificationCenter.defaultCenter removeObserver:self name:MCToolRegistryDidChangeNotification object:_toolRegistryStore];
    _toolRegistryStore = store;
    if (store) [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(registryChanged:)
        name:MCToolRegistryDidChangeNotification object:store];
    if (self.isViewLoaded) [self reloadPreservingIdentifier:[self selectedIdentifier]];
}
- (NSString *)currentGroup {
    NSInteger index = self.groups.selectedSegment;
    return @[@"screenshot", @"recording", @"videoEditing"][MAX(0, MIN(index, 2))];
}
- (NSString *)selectedIdentifier {
    NSInteger row = self.table.selectedRow;
    return row >= 0 && row < (NSInteger)self.rows.count ? self.rows[(NSUInteger)row][@"id"] : nil;
}
- (void)loadView {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 500)];
    self.groups = [NSSegmentedControl segmentedControlWithLabels:@[@"截图工具", @"录制控制", @"录后编辑"]
        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(groupChanged:)];
    self.groups.selectedSegment = 0; self.groups.accessibilityLabel = @"插件工具分类";
    self.groups.identifier = @"plugin-management-groups";
    NSTextField *hint = [NSTextField wrappingLabelWithString:@"开关控制工具是否显示；拖动行或使用下方按钮调整顺序。"];
    hint.font = [NSFont systemFontOfSize:12]; hint.textColor = NSColor.secondaryLabelColor;
    self.table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.table.identifier = @"plugin-management-table"; self.table.accessibilityLabel = @"工具显示顺序";
    self.table.headerView = nil; self.table.rowHeight = 40; self.table.allowsMultipleSelection = NO;
    self.table.allowsColumnReordering = NO; self.table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    self.table.style = NSTableViewStyleInset;
    NSTableColumn *tool = [[NSTableColumn alloc] initWithIdentifier:@"tool"];
    tool.width = 400; tool.minWidth = 240;
    NSTableColumn *enabled = [[NSTableColumn alloc] initWithIdentifier:@"enabled"];
    enabled.width = 72; enabled.minWidth = 72; enabled.maxWidth = 72;
    [self.table addTableColumn:tool]; [self.table addTableColumn:enabled];
    self.table.dataSource = self; self.table.delegate = self;
    [self.table registerForDraggedTypes:@[MCToolRowPasteboardType]];
    [self.table setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    [self.table setDraggingSourceOperationMask:NSDragOperationNone forLocal:NO];
    self.scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.scroll.hasVerticalScroller = YES; self.scroll.borderType = NSBezelBorder; self.scroll.documentView = self.table;
    self.emptyLabel = [NSTextField wrappingLabelWithString:@"暂无可管理项"];
    self.emptyLabel.alignment = NSTextAlignmentCenter; self.emptyLabel.textColor = NSColor.secondaryLabelColor;
    self.emptyLabel.font = [NSFont systemFontOfSize:13];
    self.moveUpButton = [NSButton buttonWithTitle:@"上移" target:self action:@selector(moveUp:)];
    self.moveDownButton = [NSButton buttonWithTitle:@"下移" target:self action:@selector(moveDown:)];
    self.moveUpButton.identifier = @"plugin-tool-move-up"; self.moveDownButton.identifier = @"plugin-tool-move-down";
    NSButton *importButton = [NSButton buttonWithTitle:@"导入插件…" target:nil action:nil];
    importButton.enabled = NO; importButton.identifier = @"plugin-import";
    importButton.toolTip = @"插件导入即将支持"; importButton.accessibilityHelp = @"即将支持，当前版本不可导入插件";
    NSTextField *importHint = [NSTextField labelWithString:@"即将支持"];
    importHint.font = [NSFont systemFontOfSize:11]; importHint.textColor = NSColor.secondaryLabelColor;
    NSView *spacer = [NSView new]; [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *actions = [NSStackView stackViewWithViews:@[self.moveUpButton, self.moveDownButton, spacer, importButton, importHint]];
    actions.orientation = NSUserInterfaceLayoutOrientationHorizontal; actions.spacing = 8; actions.alignment = NSLayoutAttributeCenterY;
    self.feedback = [NSTextField wrappingLabelWithString:@""];
    self.feedback.font = [NSFont systemFontOfSize:11]; self.feedback.textColor = NSColor.secondaryLabelColor;
    for (NSView *view in @[self.groups, hint, self.scroll, self.emptyLabel, actions, self.feedback]) {
        view.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.groups.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:20],
        [self.groups.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [hint.topAnchor constraintEqualToAnchor:self.groups.bottomAnchor constant:14],
        [hint.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [hint.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.scroll.topAnchor constraintEqualToAnchor:hint.bottomAnchor constant:12],
        [self.scroll.leadingAnchor constraintEqualToAnchor:hint.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:hint.trailingAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:actions.topAnchor constant:-12],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.scroll.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.scroll.centerYAnchor],
        [self.emptyLabel.widthAnchor constraintLessThanOrEqualToAnchor:self.scroll.widthAnchor constant:-32],
        [actions.leadingAnchor constraintEqualToAnchor:hint.leadingAnchor],
        [actions.trailingAnchor constraintEqualToAnchor:hint.trailingAnchor],
        [actions.bottomAnchor constraintEqualToAnchor:self.feedback.topAnchor constant:-10],
        [self.feedback.leadingAnchor constraintEqualToAnchor:hint.leadingAnchor],
        [self.feedback.trailingAnchor constraintEqualToAnchor:hint.trailingAnchor],
        [self.feedback.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-20],
        [self.feedback.heightAnchor constraintGreaterThanOrEqualToConstant:30],
    ]];
    [self reloadPreservingIdentifier:nil];
}
- (void)reloadPreservingIdentifier:(NSString *)identifier {
    self.rows = [self.toolRegistryStore toolsForGroup:[self currentGroup]] ?: @[];
    [self.table reloadData];
    NSUInteger selected = [self.rows indexOfObjectPassingTest:^BOOL(NSDictionary *tool, __unused NSUInteger index, __unused BOOL *stop) {
        return [tool[@"id"] isEqualToString:identifier];
    }];
    if (selected != NSNotFound) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:selected] byExtendingSelection:NO];
    else [self.table deselectAll:nil];
    self.emptyLabel.hidden = self.rows.count != 0;
    self.emptyLabel.stringValue = self.toolRegistryStore ? @"暂无可管理项" : @"工具管理尚未初始化";
    self.feedback.stringValue = self.toolRegistryStore.loadError ? @"上次工具设置无法读取，当前显示默认布局。修改后将替换原设置。" : @"设置自动保存，新加入的工具显示在列表末尾。";
    self.feedback.textColor = self.toolRegistryStore.loadError ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    [self updateMoveButtons];
}
- (void)updateMoveButtons {
    NSInteger row = self.table.selectedRow;
    self.moveUpButton.enabled = row > 0;
    self.moveDownButton.enabled = row >= 0 && row + 1 < (NSInteger)self.rows.count;
}
- (void)groupChanged:(__unused id)sender {
    self.draggedIdentifier = nil; self.draggedGroup = nil;
    [self reloadPreservingIdentifier:nil];
}
- (void)registryChanged:(__unused NSNotification *)notification {
    [self reloadPreservingIdentifier:[self selectedIdentifier]];
}
- (void)tableViewSelectionDidChange:(__unused NSNotification *)notification { [self updateMoveButtons]; }
- (NSInteger)numberOfRowsInTableView:(__unused NSTableView *)tableView { return (NSInteger)self.rows.count; }
- (NSImage *)iconForTool:(NSDictionary *)tool {
    NSDictionary *icons = @{@"builtin.image.rectangle":@(MC_ICON_RECTANGLE), @"builtin.image.arrow":@(MC_ICON_ARROW),
        @"builtin.image.text":@(MC_ICON_TEXT), @"builtin.image.cover":@(MC_ICON_REDACT)};
    NSNumber *icon = icons[tool[@"id"]];
    NSImage *image = icon ? MCIconImage((MCIcon)icon.integerValue, tool[@"title"]) : nil;
    return image ?: [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension" accessibilityDescription:@"工具"];
}
- (NSView *)tableView:(__unused NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSDictionary *tool = self.rows[(NSUInteger)row];
    if ([column.identifier isEqualToString:@"enabled"]) {
        NSButton *toggle = [NSButton checkboxWithTitle:@"显示" target:self action:@selector(toggleTool:)];
        toggle.identifier = tool[@"id"]; toggle.state = [tool[@"enabled"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        toggle.accessibilityLabel = [NSString stringWithFormat:@"显示%@", tool[@"title"]];
        return toggle;
    }
    NSTableCellView *cell = [NSTableCellView new];
    NSImageView *image = [[NSImageView alloc] initWithFrame:NSZeroRect]; image.image = [self iconForTool:tool];
    NSTextField *label = [NSTextField labelWithString:tool[@"title"] ?: @"工具"];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    image.translatesAutoresizingMaskIntoConstraints = label.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:image]; [cell addSubview:label]; cell.imageView = image; cell.textField = label;
    [NSLayoutConstraint activateConstraints:@[
        [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
        [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [image.widthAnchor constraintEqualToConstant:20], [image.heightAnchor constraintEqualToConstant:20],
        [label.leadingAnchor constraintEqualToAnchor:image.trailingAnchor constant:10],
        [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}
- (void)showError:(NSError *)error {
    self.feedback.stringValue = error.localizedDescription ?: @"无法修改工具设置。";
    self.feedback.textColor = NSColor.systemRedColor;
    NSAccessibilityPostNotification(self.feedback, NSAccessibilityValueChangedNotification);
}
- (void)toggleTool:(NSButton *)sender {
    NSString *identifier = sender.identifier;
    NSError *error = nil;
    BOOL changed = [self.toolRegistryStore setTool:identifier enabled:sender.state == NSControlStateValueOn error:&error];
    [self reloadPreservingIdentifier:identifier];
    if (!changed) [self showError:error];
}
- (BOOL)moveIdentifier:(NSString *)identifier before:(NSString *)before {
    NSError *error = nil;
    BOOL changed = [self.toolRegistryStore moveTool:identifier inGroup:[self currentGroup] beforeTool:before error:&error];
    [self reloadPreservingIdentifier:identifier];
    if (!changed) [self showError:error];
    return changed;
}
- (void)moveUp:(__unused id)sender {
    NSInteger row = self.table.selectedRow;
    if (row > 0) [self moveIdentifier:self.rows[(NSUInteger)row][@"id"] before:self.rows[(NSUInteger)row - 1][@"id"]];
}
- (void)moveDown:(__unused id)sender {
    NSInteger row = self.table.selectedRow;
    if (row < 0 || row + 1 >= (NSInteger)self.rows.count) return;
    NSString *before = row + 2 < (NSInteger)self.rows.count ? self.rows[(NSUInteger)row + 2][@"id"] : nil;
    [self moveIdentifier:self.rows[(NSUInteger)row][@"id"] before:before];
}
- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
    if (tableView != self.table || row < 0 || row >= (NSInteger)self.rows.count) return nil;
    self.draggedIdentifier = self.rows[(NSUInteger)row][@"id"]; self.draggedGroup = [self currentGroup];
    NSPasteboardItem *item = [NSPasteboardItem new];
    [item setString:self.draggedIdentifier forType:MCToolRowPasteboardType];
    return item;
}
- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)operation {
    NSString *identifier = [info.draggingPasteboard stringForType:MCToolRowPasteboardType];
    if (tableView != self.table || info.draggingSource != self.table || operation != NSTableViewDropAbove ||
        row < 0 || row > (NSInteger)self.rows.count || ![self.draggedGroup isEqualToString:[self currentGroup]] ||
        ![identifier isEqualToString:self.draggedIdentifier]) return NSDragOperationNone;
    for (NSDictionary *tool in self.rows) if ([tool[@"id"] isEqualToString:identifier]) return NSDragOperationMove;
    return NSDragOperationNone;
}
- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)operation {
    if ([self tableView:tableView validateDrop:info proposedRow:row proposedDropOperation:operation] != NSDragOperationMove) return NO;
    NSString *identifier = [info.draggingPasteboard stringForType:MCToolRowPasteboardType];
    NSString *before = row < (NSInteger)self.rows.count ? self.rows[(NSUInteger)row][@"id"] : nil;
    if ([identifier isEqualToString:before]) return YES;
    return [self moveIdentifier:identifier before:before];
}
- (void)tableView:(__unused NSTableView *)tableView draggingSession:(__unused NSDraggingSession *)session endedAtPoint:(__unused NSPoint)point operation:(__unused NSDragOperation)operation {
    self.draggedIdentifier = nil; self.draggedGroup = nil;
}
- (void)invalidate {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    self.table.delegate = nil; self.table.dataSource = nil;
    self.toolRegistryStore = nil;
    self.draggedIdentifier = nil; self.draggedGroup = nil;
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
