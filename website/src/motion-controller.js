/** Keep the renderer off the initial page path and enforce viewport/page/user policy. */
export function createMotionController({
  load,
  mount,
  onState = () => {},
  onReady = () => {},
  onError = () => {},
}) {
  let visible = false,
    hidden = false,
    reduced = false,
    userPaused = false,
    manual = false;
  let renderer,
    player,
    pending,
    failed = false,
    disposed = false;
  const running = () =>
    visible &&
    !hidden &&
    !userPaused &&
    (!reduced || manual) &&
    !failed &&
    !disposed;
  const fail = (error) => {
    failed = true;
    player?.destroy();
    player = undefined;
    onError(error);
    onState(false);
  };
  function reconcile() {
    if (disposed) return;
    const active = running();
    onState(active);
    if (player) {
      player.update(active);
      return;
    }
    if (!active) return;
    if (renderer) {
      try {
        player = mount(renderer, { onReady, onError: fail });
        player.update(running());
      } catch (error) {
        fail(error);
      }
      return;
    }
    if (!pending) {
      pending = load()
        .then((module) => {
          renderer = module;
          // Recheck visibility after downloading: never mount a now-offscreen player.
          reconcile();
        })
        .catch(fail);
    }
  }
  return {
    setVisible(value) {
      visible = value;
      reconcile();
    },
    setHidden(value) {
      hidden = value;
      reconcile();
    },
    setReduced(value) {
      reduced = value;
      manual = false;
      reconcile();
    },
    toggle() {
      if (reduced && !manual) {
        manual = true;
        userPaused = false;
      } else userPaused = !userPaused;
      reconcile();
    },
    dispose() {
      disposed = true;
      player?.destroy();
      player = undefined;
    },
  };
}
