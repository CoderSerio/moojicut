import test from "node:test";
import assert from "node:assert/strict";
import { createMotionController } from "../src/motion-controller.js";

function harness() {
  const events = [];
  let resolve, reject;
  const promise = new Promise((yes, no) => {
    resolve = yes;
    reject = no;
  });
  const controller = createMotionController({
    load: () => {
      events.push("load");
      return promise;
    },
    mount: () => {
      events.push("mount");
      return {
        update: (value) => events.push(value ? "play" : "pause"),
        destroy: () => events.push("destroy"),
      };
    },
    onError: () => events.push("error"),
  });
  return {
    controller,
    events,
    resolve,
    reject,
    tick: () => new Promise(setImmediate),
  };
}

test("no import before visibility; an import that finishes offscreen does not mount", async () => {
  const h = harness();
  h.controller.setHidden(false);
  h.controller.setReduced(false);
  assert.deepEqual(h.events, []);
  h.controller.setVisible(true);
  assert.deepEqual(h.events, ["load"]);
  h.controller.setVisible(false);
  h.resolve({});
  await h.tick();
  assert.deepEqual(h.events, ["load"]);
  h.controller.setVisible(true);
  assert.deepEqual(h.events, ["load", "mount", "play"]);
  h.controller.setVisible(false);
  assert.equal(h.events.at(-1), "pause");
});

test("hidden tabs stop playback; a user pause survives reentry and tab changes", async () => {
  const h = harness();
  h.controller.setVisible(true);
  h.resolve({});
  await h.tick();
  h.controller.setHidden(true);
  assert.equal(h.events.at(-1), "pause");
  h.controller.setHidden(false);
  assert.equal(h.events.at(-1), "play");
  h.controller.toggle();
  h.controller.setVisible(false);
  h.controller.setVisible(true);
  h.controller.setHidden(true);
  h.controller.setHidden(false);
  assert.equal(h.events.at(-1), "pause");
  h.controller.toggle();
  assert.equal(h.events.at(-1), "play");
});

test("reduced motion uses the poster until explicit play, including preference changes", async () => {
  const h = harness();
  h.controller.setReduced(true);
  h.controller.setVisible(true);
  assert.deepEqual(h.events, []);
  h.controller.toggle();
  h.resolve({});
  await h.tick();
  assert.equal(h.events.at(-1), "play");
  h.controller.setReduced(true);
  assert.equal(h.events.at(-1), "pause");
});

test("hidden page does not start an import; failed downloads leave a static fallback", async () => {
  const h = harness();
  h.controller.setHidden(true);
  h.controller.setVisible(true);
  assert.deepEqual(h.events, []);
  h.controller.setHidden(false);
  h.reject(new Error("offline"));
  await h.tick();
  h.controller.setVisible(false);
  h.controller.setVisible(true);
  assert.deepEqual(h.events, ["load", "error"]);
});

test("teardown during a pending import cannot mount later", async () => {
  const h = harness();
  h.controller.setVisible(true);
  h.controller.dispose();
  h.resolve({});
  await h.tick();
  assert.deepEqual(h.events, ["load"]);
});
