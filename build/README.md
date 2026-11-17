# Native build ownership

`native-modules.json` describes application and helper compilation, not runtime
plugin discovery. The runtime contribution catalog and user Wasm packages are
separate MoonBit/plugin concerns.

- `sources`: independent compilation units linked by the requested module's
  `requires` closure. User-imported code is never scanned or compiled here.
- `files`: owned headers, included fragments and native packaging resources.
  A `.c`, `.cpp`, `.m`, `.mm` or `.swift` file cannot hide here and miss compilation.
- `requires`: linked module dependencies. The resolver rejects missing modules,
  duplicate ownership and dependency cycles, including unrequested modules.
- `includes`: header-only dependencies. They authorize inspected imports without
  adding another implementation to a fixture's link command.
- `shared`: platform-independent ABI declarations and low-level code/assets.
- `tool.*`: separately compiled helpers; the application does not link them.
- `legacy_includes`: exact existing file pairs with an explained migration task.
  Removing that import makes the exception fail, requiring its removal too.

`scripts/check_native_boundaries.py` checks actual literal quoted and angle
includes against this ownership and dependency graph. Platform adapters cannot
import product features; reusable components cannot import application/feature
code; cross-feature coordination belongs in the application. Macro-computed
includes are rejected because their target cannot be checked statically.

The checker also finds unregistered source files, headers, `.inc` fragments and
native packaging resources under `native`, `components`, `plugins/feature`,
`platform` and `bindings`. It does not pretend to validate every third-party
library, framework or generated asset shipped by the packaging scripts. Those
continue to have their existing build and package checks.

Every `native_sources()` call used by the application build, helper build and
native fixtures runs this check. To run it directly:

```sh
python3 scripts/check_native_boundaries.py
python3 scripts/native_modules.py all
python3 -m unittest discover -s test/build -v
```

The listed legacy exceptions are unfinished migrations, not permission to add
another product dependency to a platform or component. New functionality keeps
its rules and UI in MoonBit; native code implements the required system ports.
