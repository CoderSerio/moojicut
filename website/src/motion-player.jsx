import React, { useEffect, useRef } from "react";
import { createRoot } from "react-dom/client";
import { Player } from "@remotion/player";
import { useCurrentFrame } from "remotion";
import { Scene } from "./scenes.jsx";

function Composition({ kind }) {
  return <Scene kind={kind} frame={useCurrentFrame()} />;
}
function Motion({ kind, running, onReady, onError }) {
  const player = useRef(null);
  useEffect(() => {
    onReady();
  }, [onReady]);
  useEffect(() => {
    if (running) player.current?.play();
    else player.current?.pause();
  }, [running]);
  return (
    <Player
      ref={player}
      component={Composition}
      inputProps={{ kind }}
      durationInFrames={240}
      fps={30}
      compositionWidth={1000}
      compositionHeight={560}
      loop
      // Silent illustrations must not wait for an audio-context user gesture.
      initiallyMuted
      controls={false}
      clickToPlay={false}
      doubleClickToFullscreen={false}
      spaceKeyToPlayOrPause={false}
      numberOfSharedAudioTags={0}
      style={{ width: "100%", height: "100%" }}
      errorFallback={() => {
        queueMicrotask(onError);
        return null;
      }}
    />
  );
}
export function mountPlayer(element, kind, { onReady, onError }) {
  const root = createRoot(element);
  return {
    update(running) {
      root.render(
        <Motion
          kind={kind}
          running={running}
          onReady={onReady}
          onError={onError}
        />,
      );
    },
    destroy() {
      root.unmount();
    },
  };
}
