# External libraries

**Note: This proposal is still in a really rough strawman shape. I wanted to
get enough written to start talking about it but didn't have time to go into
full detail. Rest assured that the detail will come.**

* Author: [Bob Nystrom][bob] ([rnystrom@google.com][email])
* Repository: https://github.com/munificent/dep-external-libraries
* Stakeholders: [Lasse][]

[bob]: https://github.com/munificent
[email]: mailto:rnystrom@google.com
[lasse]: https://github.com/lrhn

## Summary

A user can create a library with a configuration-independent public API but
whose contents are partially defined in separate configuration-specific files.
This gives you the ability to write code that takes advantages of features only
available a single configuration, where "configuration" means something like
"dart2js", "the standalone VM", etc.

At the same time, the library defines a single canonical static structure that
can be used to provide a unified analysis and IDE experience. In other words,
when *editing* code, the user just sees it as a single library. When *running*
it, the correct code is patched in for the configuration that the program is
running in.

*TL;DR: Take the "patch file" concept we already use in the core libraries and
make something similar that users can also use.*

## Motivation

From its inception, Dart has run on top of multiple different "platforms": the
native VM running on the console, Dartium, compiled to JavaScript, etc. These
implementations vary in their capabilities, which is why some core libraries
like "dart:io" and "dart:html" are only allowed on certain platforms. As we
move into ever-more-diverse mobile platforms, this problem will magnify. We may
find ourselves with "dart:android", "dart:ios", etc.

Often, different platforms *do* have the same capability, just exposed through
a different API. You can do HTTP and WebSockets in the browser and on the
command-line, but you can't do them using the same API.

Users want to write platform-independent libraries that hide these differences,
but can't. It's impossible to write a cross-platform library if it needs to
touch anything platform-specific. If your library imports "dart:html", it fails
*at compile time* on the standalone VM. You never get to `main()`.

This is a *transitive* property. If your application imports a package that
imports some other package that imports a library that ultimately imports
"dart:io", you can never ever run your application on a browser *even if it
never accesses "dart:io" at runtime.*

For example, the [unittest][] package would like to report test failures on a
browser by adding elements to the DOM. On the standalone VM, it would like to
write to stderr. Likewise, the [http][] package would like to make HTTP
requests using "dart:io"'s [`HttpClient`][io client] class when used on the
command-line while using an [`HttpRequest`][html request] on the browser.

[unittest]: https://pub.dartlang.org/packages/unittest
[http]: https://pub.dartlang.org/packages/http
[io client]: https://api.dartlang.org/apidocs/channels/stable/dartdoc-viewer/dart:io.HttpClient
[html request]: https://api.dartlang.org/apidocs/channels/stable/dartdoc-viewer/dart:html.HttpRequest

There's currently no way to write a single library that can span these
platforms and use the right library where appropriate. Even if it can avoid
touching the unsupported library at *runtime*, the mere presence of the
`import` prevents the program from running at all.

### Patch files

Interestingly, the core libraries themselves also have this problem.
"dart:core" needs to eventually bottom out at C++ code in the native VM, and in
snippets of JS in dart2js. So while there is a single "canonical" "dart:core"
that defines its *static API*, much of its *implementation* is delegated to
platform-specific machinery.

This machinery is called "patch files", and is not part of the language spec.
What *is* in the language spec is *external functions*. These are declarations
of functions whose definitions are left up to the implementation to provide.

This proposal is turns these into something end users can also use.

## Examples

We'll start simple. Say you want to write a library for showing warnings to the
user. It exposes a single function:

```dart
void warn(String message) {
  ...
}
```

You want this library to be usable on every Dart platform. Moreso, its
behavior should be *tailored* to the platform it's running on. On the browser,
it should show a warning by adding some elements to the DOM. On the standalone
VM, it should print to stderr.

Using this proposal, you would write:

```dart
// warn.dart
external library 'warn_browser.dart' for dart.html;
external library 'warn_console.dart' for dart.io;

/// Warns the user about [message].
external void warn(String message);
```

We'll call this the *canonical library*. It in turn refers to two separate
*external libraries*:

```dart
// warn_browser.dart
import 'dart:html';

void warn(String message) {
  html.document.body.appendHtml('<div class="warn">$message</div>');
}
```

and:

```dart
// warn_console.dart
import 'dart:io';

void warn(String message) {
  io.stderr.writeLine(message);
}
```

This "warn.dart" library can be used like any normal Dart library:

```dart
// main.dart
import 'warn.dart';

void main() {
  warn("This proposal is still in progress!");
}
```

When the program is run, an external library is selected that matches the host
platform. For example, if the user runs this on the standalone VM,
'warn_console.dart' is selected. The VM reads that library. It finds the
concrete definition of `warn()` and patches it in where the `external` one was
declared in "warn.dart".

Likewise, if a user runs this in Dartium or compiles it with dart2js, the
browser version is inserted instead.

When the user is just editing their code in their favorite IDE of choice, the
external libraries are ignored. She just sees a single "warn.dart" and the
public API it defines.

### A cross-platform HTTP client

Here's another example. We'll sketch out very roughly how the http package
could use this. Its canonical library defines a `Client` class for performing
HTTP requests. This is the platform-independent public API of the package:

```dart
// http.dart

external library 'io_client.dart' for dart.io;
external library 'browser_client.dart' for dart.html;

abstract class Client {
  external Client();

  /// Sends an HTTP GET request with the given headers to the given URL, which
  /// can be a [Uri] or a [String].
  external Future<Response> get(url, {Map<String, String> headers});

  /// Sends an HTTP POST request with the given headers and body to the given
  /// URL, which can be a [Uri] or a [String].
  external Future<Response> post(url, {Map<String, String> headers, body,
      Encoding encoding});

  // More code...
}
```

Note that even its constructor is external. This class may also contain real
implementation code for behavior that is already platform-independent. It
doesn't have to be a pure interface.

Then there are the two external libraries:

```dart
// io_client.dart

import 'dart:io';

/// A `dart:io`-based HTTP client.
///
/// This is the default client when running on the command line.
class Client extends BaseClient {
  // Fields...

  Client() {
    // Use dart:io...
  }

  Future<Response> get(url, {Map<String, String> headers}) {
    // Use dart:io...
  }

  Future<Response> post(url, {Map<String, String> headers, body,
      Encoding encoding}) {
    // Use dart:io...
  }

}
```

The browser one is similar. You get the idea. Now we'll get into the details
about how this actually works.

## Proposal

**TODO: I will specify this more precisely over time. Yes, I know it's
hand-wavey.**

### Runtime behavior

To process a library using this feature, an implementation:

1.  Determines which external library should be chosen for the current
    implementation. *(TODO: Decide how to handle multiple or no external
    libraries matching.)*

2.  The canonical library and external library's bodies are "compiled" (i.e.
    names resolved, etc.) in their own scopes. In other words, the canonical
    library and external library may have different imports from each other and
    the two don't interfere.

    For example:

    ```dart
    // canonical.dart
    external library 'external.dart' for true;

    import 'foo.dart' show someName;

    main() {
      print(someName); // "foo"
    }

    external inExternal();
    ```

    ```dart
    // external.dart

    import 'bar.dart' show someName;

    inExternal() {
      print(someName); // "bar"
    }
    ```

    This produces two namespaces, the canonical and external one.

    Note that this happens *after* step 1. This ensures that a runtime never
    sees an import for a core library it doesn't support.

3.  Every top-level name in the canonical library not already used in the
    external library is added to the external library.

    For example:

    ```dart
    // canonical.dart
    external library 'external.dart' for true;

    var a = "canonical";
    var b = "canonical";

    main() {
      accessVars();
    }
    ```

    ```dart
    // external.dart

    b = "external";

    accessVars() {
      print(a); // "canonical"
      print(b); // "external"
    }
    ```

4.  When two classes overlap, their namespaces are handled the same way: all
    members of the canonical class not present in the external one are added.

    For example:

    ```dart
    // canonical.dart
    external library 'external.dart' for true;

    class Foo {
      a() => "canonical";
      b() => "canonical";

      callMethods() {
        print(a()); // "canonical"
        print(b()); // "external"
      }
    }

    main() {
      new Foo().callMethods();
    }
    ```

    ```dart
    // external.dart

    class Foo {
      b() => "external";
    }
    ```

    *TODO: Decide how the canonical class's superinterfaces, superclass, and
    mixins are handled.**

5.  The result of this then becomes the namespace of the that all other code
    sees.

### Static analysis

A key feature of this proposal is that its static analysis story is very
simple. IDEs, analyzers and other tools only look at the canonical library and
that defines the "official" static API of the library.

This gives the user a simpler IDE experience&mdash;they can navigate around in
their program without having think about what "configuration" their program is
in.

At the same time, a sophisticated analyzer may want to add some additional
hinting beyond that. For example, it would helpful for the *implementer* of a
cross-platform library to know if they forgot to provide a definition for some
`external` function, or it the signature of one they provided doesn't match its
declaration.

## Alternatives

There have been a large number of attempts at solutions in this problem space
over the years. The current other active proposal is Lasse's [configured
imports DEP][].

[configured imports dep]: https://github.com/lrhn/dep-configured-imports

The fundamental difference between the proposals is how configuration affects
the *static* structure of the program. With this proposal, the external
libraries are ignored by analysis and only the canonical library is analyzed.
Lasse's proposal allows different configured imports to expose a different
public API.

This means analysis either has to try to "union" them together to provide a
holistic view of all configurations simultaneously, or provide a way for a user
to select which configuration they are currently looking at. In return for
that, it can express some things this proposal cannot.

## Implications and limitations

**TODO!**

## Deliverables

**TODO!**

### Language specification changes

### A working implementation

**TODO!**

### Tests

**TODO!**

## Patents rights

TC52, the Ecma technical committee working on evolving the open [Dart standard][], operates under a royalty-free patent policy, [RFPP][] (PDF). This means if the proposal graduates to being sent to TC52, you will have to sign the Ecma TC52 [external contributer form][] and submit it to Ecma.

[tex]: http://www.latex-project.org/
[language spec]: https://www.dartlang.org/docs/spec/
[dart standard]: http://www.ecma-international.org/publications/standards/Ecma-408.htm
[rfpp]: http://www.ecma-international.org/memento/TC52%20policy/Ecma%20Experimental%20TC52%20Royalty-Free%20Patent%20Policy.pdf
[external contributer form]: http://www.ecma-international.org/memento/TC52%20policy/Contribution%20form%20to%20TC52%20Royalty%20Free%20Task%20Group%20as%20a%20non-member.pdf
