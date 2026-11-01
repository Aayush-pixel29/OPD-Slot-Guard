// Conditional export for cross-platform SQLite initialization.
export 'database_initializer_stub.dart'
    if (dart.library.io) 'database_initializer_io.dart'
    if (dart.library.js_interop) 'database_initializer_web.dart';

