#!/usr/bin/env python3
"""Force the lifecycle server's bind to fail with a chosen signature."""

import errno
import importlib.util
import os
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("plugin_lifecycle_smarthttp", path)
if spec is None or spec.loader is None:
    raise RuntimeError("could not load smart-HTTP helper")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


class ForcedBindFailure:
    def __init__(self, *_args: object, **_kwargs: object) -> None:
        if os.environ["SMART_HTTP_BIND_FAILURE"] == "sandbox":
            raise PermissionError(errno.EPERM, "Operation not permitted")
        raise OSError(errno.EADDRINUSE, "Address already in use")


module.__dict__["GitHTTPServer"] = ForcedBindFailure
sys.argv = [path, ".", sys.argv[2]]
raise SystemExit(module.main())
