import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { writeFileSync, mkdirSync } from "node:fs";
import { Scene } from "../src/scenes.jsx";
const destination = new URL("../public/assets/", import.meta.url);
mkdirSync(destination, { recursive: true });
for (const kind of ["capture", "pin", "edit"]) {
  writeFileSync(
    new URL(`demo-${kind}.svg`, destination),
    renderToStaticMarkup(<Scene kind={kind} frame={180} />),
  );
}
