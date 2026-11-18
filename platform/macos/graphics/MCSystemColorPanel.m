#import "MCSystemColorPanel.h"

@class MCSystemColorPanelRouter;
@interface MCSystemColorPanelLease ()
@property (nonatomic, weak) id owner;
@property (nonatomic, copy) void (^handler)(id owner, NSColor *color);
@property (nonatomic) uint64_t identity;
@property (nonatomic) BOOL invalidated;
@end
@interface MCSystemColorPanelRouter : NSObject
@property (nonatomic, weak) MCSystemColorPanelLease *lease;
@property (nonatomic) uint64_t identity;
@property (nonatomic) NSUInteger silentDepth;
- (void)colorChanged:(NSColorPanel *)sender;
@end
static MCSystemColorPanelRouter *MCPanelRouter(void) {
    static MCSystemColorPanelRouter *router;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ router = [MCSystemColorPanelRouter new]; });
    return router;
}
@implementation MCSystemColorPanelRouter
- (void)colorChanged:(NSColorPanel *)sender {
    NSAssert(NSThread.isMainThread, @"System color input belongs to the UI thread");
    if (self.silentDepth || !NSColorPanel.sharedColorPanelExists || sender != NSColorPanel.sharedColorPanel) return;
    MCSystemColorPanelLease *lease = self.lease;
    id owner = lease.owner;
    if (!owner) { [lease invalidate]; return; }
    if (!lease.isActive) return;
    void (^callback)(id,NSColor *) = lease.handler;
    NSColor *color = sender.color;
    if (callback) callback(owner,color);
    // A callback may replace the lease or destroy its UI. Do not touch the
    // panel/owner after dispatch or assume this lease is still authoritative.
}
@end
@implementation MCSystemColorPanelLease
+ (instancetype)beginWithOwner:(id)owner color:(NSColor *)color showsAlpha:(BOOL)showsAlpha
                      onColor:(void (^)(id, NSColor *))handler {
    NSAssert(NSThread.isMainThread, @"System color input belongs to the UI thread");
    MCSystemColorPanelRouter *router = MCPanelRouter();
    [router.lease invalidate];
    NSColorPanel *panel = NSColorPanel.sharedColorPanel;
    panel.target = nil; panel.action = NULL;
    static uint64_t nextIdentity = 1;
    MCSystemColorPanelLease *lease = [self new];
    lease.owner = owner; lease.handler = handler;
    if (nextIdentity == UINT64_MAX) {
        // Do not reuse an identity even after impractical lifetime exhaustion.
        lease.invalidated = YES; router.lease = nil; router.identity = 0;
        return lease;
    }
    lease.identity = nextIdentity++;
    router.lease = lease; router.identity = lease.identity;
    router.silentDepth++;
    panel.showsAlpha = showsAlpha;
    if (router.identity == lease.identity) panel.color = color;
    router.silentDepth--;
    if (router.identity == lease.identity) {
        panel.target = router; panel.action = @selector(colorChanged:);
    }
    return lease;
}
- (BOOL)isActive {
    if (self.invalidated || !self.owner || !NSColorPanel.sharedColorPanelExists) return NO;
    MCSystemColorPanelRouter *router = MCPanelRouter();
    return router.identity == self.identity && router.lease == self;
}
- (void)updateColor:(NSColor *)color {
    NSAssert(NSThread.isMainThread, @"System color input belongs to the UI thread");
    if (!self.isActive) return;
    MCSystemColorPanelRouter *router = MCPanelRouter();
    NSColorPanel *panel = NSColorPanel.sharedColorPanel;
    router.silentDepth++;
    panel.target = nil; panel.action = NULL;
    panel.color = color;
    router.silentDepth--;
    // Setter-side observers can synchronously transfer ownership.
    if (!self.invalidated && self.owner && router.identity == self.identity && router.lease == self) {
        panel.target = router; panel.action = @selector(colorChanged:);
    }
}
- (void)invalidate {
    NSAssert(NSThread.isMainThread, @"System color input belongs to the UI thread");
    if (self.invalidated) return;
    self.invalidated = YES;
    MCSystemColorPanelRouter *router = MCPanelRouter();
    if (router.identity == self.identity) {
        router.identity = 0; router.lease = nil;
        if (NSColorPanel.sharedColorPanelExists) {
            NSColorPanel *panel = NSColorPanel.sharedColorPanel;
            panel.target = nil; panel.action = NULL;
        }
    }
    self.handler = nil;
}
- (void)dealloc { [self invalidate]; }
@end
