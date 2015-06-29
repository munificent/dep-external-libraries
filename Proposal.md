# External libraries

* Author: [Bob Nystrom][bob] ([rnystrom@google.com][email])
* Repository: https://github.com/munificent/dep-external-libraries
* Stakeholders: [Lasse][]

[bob]: https://github.com/munificent
[email]: mailto:rnystrom@google.com
[lasse]: https://github.com/lrhn

## Motivation

The Dart language does not exist in a vacuum:

 *  An application may run on both the standalone VM where it has access to
    "dart:io" and a browser where it can use "dart:html".

 *  An application may be compiled to JavaScript and use the JS DOM.

 *  A core library type like String may be implemented partially or completely
    in C++ in the native VM. Meanwhile, that same class may be implemented in
    JavaScript when compiled with dart2js.

 *  A custom embedder like [Sky][] may want to expose new behavior written in
    C++ to end user Dart programs.

[sky]: https://github.com/domokit/mojo/tree/master/sky

In all of these cases, the user's code reaches out towards some functionality
that may not be available or even comprehensible by every tool in the Dart
platform.

Since we have focused mostly on building a platform-independent Dart world, we
haven't built a robust system for code that cares about where it's running.
Instead, we've grown a handful of ad-hoc solutions:

 1. Our core libraries are partially platform independent and partially
    platform (i.e. VM or dart2js) specific. For each core library, there is a
    "main" platform independent library. That library declares some methods as
    `external` to indicate that the implementation is platform-specific.

 2. Then, there is a "patch" Dart file for each platform. This uses a `@patch`
    annotation or `patch` keyword to mark a class or method as providing
    implementations for some of the external methods in the main library.

 3. In the VM's patch file, some methods are in turn declared `native` followed
    by a string literal. This marks the method as being implemented by a native
    C++ method that can be located by the VM using the given string name.

 4. In the patch file for dart2js, `native` is used in a similar way but
    without a string literal. Instead native methods have a few metadata
    annotations describing how they interact with the underlying JS DOM.

 5. dart2js also defines some methods whose implementation is a chunk of inline
    JavaScript. This is done by having the method body call a `JS()` function
    whose argument is the string of JavaScript code.

Aside from the `external` keyword, none of these features are specified or
officially supported by the Dart platform. Many of them are only enabled inside
"dart:" libraries, and the set of those is in turn [hardcoded in the
SDK][hard].

[hard]: https://github.com/dart-lang/sdk/blob/master/sdk/lib/_internal/libraries.dart

This means that when external Dart users run into these problems, they don't
have the solutions we've given ourselves. This proposal solves that by
cleaning up and rationalizing these existing features into a simple system that
is both powerful enough for us to replace our old ad-hoc solutions and useful
enough to specify and give to end users.

## Summary

**A pure Dart library declares a static API. It omits some of its
implementation by declaring functions `external`. These are then provided by
either another Dart library, or through some other mechanism outside of the
core Dart platform.**

This gives a Dart implementation&mdash;VM, compiler, custom embedder,
etc.&mdash;the power to add capabilities to Dart. Meanwhile, the static
analysis story (type checking, IDE navigation, etc.) remains full-featured and
usable. Since there is always a *static declaration* of the library's API
written in standard Dart code, tools always have a coherent view of the
program.

We then build on top of this core concept by specifying a couple of different
concrete ways an implementation of one of these declared libraries may be wired
in:

 *  The implementation may simply be a separate hard-coded normal Dart library.

 *  The implementation may be one of a handful of configuration-specific Dart
    libraries chosen at runtime or compile time by a Dart implementation.

 *  The implementation may be handled entirely outside of the platform by a
    custom embedder or compiler-specific features.

## Examples

We'll walk through a progression of use cases to incrementally build all of the
features of the proposal.

### Example 1: Weaving in generated code

Say you are building a serialization system. Given some hand-authored class,
you'd like to be able to automatically serialize it to and from JSON. You, of
course, want to do this efficiently with small dart2js output. That means
avoiding mirrors.

One easy way to do this is using offline code generation. You can use the
[source_gen][] package to create a little code generator. It parses your
hand-authored class to find its fields and outputs a blob of Dart code to
convert objects to and from JSON.

[source_gen]: https://github.com/dart-lang/source_gen

The question is, where do we put this blob of code? Ideally, it would go in a
separate file. Mixing hand-maintained and generated code in the same file
causes user pain and usually breaks the code generator. However, we'd really
like the serialization API to hang off the hand-authored class. Given:

```dart
class Person {
  final String name;
  final int age;

  Person(this.name, this.age);
}
```

We want other code to be able to do:

```dart
Person roundtrip(Person person) {
  var json = person.toJson();
  return new Person.fromJson(json);
}
```

How can we have `toJson()` and `Person.fromJson()` be *declared* in the
hand-authored library but *implemented* in another file? Like so:

```dart
external library 'person.g.dart';

class Person {
  final String name;
  final int age;

  Person(this.name, this.age);

  external Person.fromJson(Map json);

  external Map toJson();
}
```

There are a few pieces here:

**1. Canonical library**

We'll call the hand-authored library here the *canonical* library. A canonical
library is the starting point for this whole proposal.

**2. External members**

A member or function can be declared `external` to delegate its implementation
elsewhere. This is exactly how the language already specifies `external`, so
we're just using that existing feature. It says, "at runtime, this member will
exist *somehow* so statically just pretend it already does".

Since the declaration is in pure Dart code and has a full type signature, the
analyzer and all of our static analysis tools can treat it as it if were fully
present.

**3. External libraries**

Now we provide the first mechanism to define what "elsewhere" means. The
`external library` directive declares a second Dart *external library* that is
used to provide the implementations of the `external` methods in the current
library.

It specifies the actual URL of the external library so that starting from the
canonical library, we can find its external library. Here, it would look
something like:

```dart
external library for 'person.dart';

import 'dart:convert';

class Person {
  factory Person.fromJson(Map json) => new Person(json["name"], json["age"]);
  Map toJson() => {"name": name, "age": age};
}
```

At static analysis time, the `external library for ...` directive lets the
analyzer know what canonical library this library is patching. This is
important for understanding the namespace of the methods inside `Person` here.
Notice how they refer to `name` and `age` even though `Person` in this library
doesn't define them? That works because analysis knows this `Person` is really
patching the "real" `Person` class defined in the canonical library.

At runtime, the method bodies for `fromJson()` and `toJson()` are slotted into
the "real" `Person` class as if they were defined right there.

### Example 2: Configuration-specific libraries

Dart runs on multiple "platforms": the native VM running on the console,
Dartium, compiled to JavaScript, etc. These implementations vary in their
capabilities, which is why some core libraries like "dart:io" and "dart:html"
are only supported on certain platforms.

Often, different platforms *do* have the same capability, just exposed through
differently. For example, the [http][] package would like to make HTTP requests
using "dart:io"'s [`HttpClient`][io client] class when run on the command-line
and using an [`HttpRequest`][html request] on the browser.

[http]: https://pub.dartlang.org/packages/http
[io client]: https://api.dartlang.org/apidocs/channels/stable/dartdoc-viewer/dart:io.HttpClient
[html request]: https://api.dartlang.org/apidocs/channels/stable/dartdoc-viewer/dart:html.HttpRequest

Alas, you can't write a single library that works across platforms because it
is a *compile error* to import a "dart:" library on an unsupported platform.
We'll fix that with a layer of indirection:

```dart
// http.dart
external library
    if (dart.io) 'io_client.dart'
    if (dart.html) 'browser_client.dart';

abstract class Client {
  external Client();

  external Future<Response> get(url, {Map<String, String> headers});

  external Future<Response> post(url, {Map<String, String> headers, body,
      Encoding encoding});
}
```

Like the above example, we have a canonical library that declares the
platform-independent API. The implementation is pushed into an external
library. The difference here is the `if` clauses:

```dart
external library
    if (dart.io) 'io_client.dart'
    if (dart.html) 'browser_client.dart';
```

**4. Configured libraries**

An external library directive may have one or more `if` clauses instead of a
straight URI. Each contains a constant expression and a URI. At runtime, that
expression is evaluated in a namespace based on [environment constants][env].
If it evaluates to `true` then that clause's URI is the external library that
gets patched in at runtime.

[env]: http://blog.sethladd.com/2013/12/compile-time-dead-code-elimination-with.html

**5. Configuration-specific libraries**

Now we get to the external library for a specific configuration. In our
example, for the standalone VM, it would look something like this:

```dart
external library for 'http.dart';

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

The important part is that we've removed the import of "dart:io" out of the
 *canonical* library and into the *external* library. On the standalone VM, we
 pick the above configuration. The standalone VM does support "dart:io" so
 everything works as expected.

On a browser, this external library is never selected. Instead, the
browser-specific one that does not import "dart:io" gets picked.

This lets a user ensure an implementation never sees a import of a "dart:"
library that it doesn't support. Since an external library can contain imports, it *lets the user control which imports are seen*.

### Example 3: Native methods in a custom embedder

Finally, we get to what may be the most interesting example. The [Sky][] team
is working on a new platform for mobile applications. They are using Dart as
the platform's scripting language. Since they operate near the OS level, they
have new low-level capabilities that they need to expose directly to
Dart&mdash;capabilities unique to the Sky platform.

The Dart VM has always been designed to be embeddable in host applications like
other scripting languages. Part of this means being able to call into native
C++ code from Dart. Currently, the VM supports this using a `native` keyword,
like:

```dart
class List {
  int get length native "List_getLength";
}
```

There is one limitation: `native` can only be used inside "dart:" libraries.
The Sky folks *could* create their own new "dart:sky" library and let users do:

```dart
import "dart:sky";
```

At runtime, all of the new capabilities would be available. Great!

But, when a user opens that program in their IDE of choice, the user experience
is *not* great. Because "dart:sky" is bundled up inside Sky's custom embedder,
the analyzer has no idea what it declares or how to find it. Any references to
names imported from "dart:sky" become static errors.

We can solve this by adding two more small features to this proposal:

**6. External strings**

One reason the VM uses `native` instead of `external` is that it allows a
string literal to follow the keyword. The VM uses this to look up the proper
C++ method to bind. It could use a metadata annotation instead:

```dart
class List {
  @Native("List_getLength")
  external int get length;
}
```

But I believe the VM wants to avoid parsing metadata annotations during
startup. If this is still a concern, we can extend the specification of
`external` to allow an optional string literal after the declaration:

```dart
class _List<E> extends FixedLengthListBase<E> {
  external int get length "List_getLength";
}
```

This gets us to a syntax closer to what is already specified in the language
and equally as expressive as `native`.

**7. Implementation-defined behavior**

The last "feature" isn't really a feature at all since it's what the language
already specifies. So far, all of the external methods we've seen have been
patched using implementations in Dart. That's fine when an external library for
that configuration is available.

If it's not, a Dart implementation can handle that how it chooses. In the case
of the VM, that means handing it off to the custom embedder. The Sky team can
define a canonical library like so:

```dart
class InternetAddress {
  external static Uint8List parse(String address) "InternetAddress_Parse";

  // Other stuff...
}
```

They put this library *in the Sky package* that gets published to pub or
however else they want to get it into users hands. A user uses it like so:

```dart
import 'package:sky/sky.dart';

main() {
  InternetAddress.parse("localhost");
}
```

In their IDE, everything works fine. This is now a regular "package:" import
that the analyzer can traverse. Since the canonical library in the package has
the declarations for `InternetAddress` and `parse()`, all of the static
analysis users know and love works.

When the user runs the program in the custom Sky embedder, the VM tells the
embedder, "The library with URL 'package:sky/sky.dart' has an external method
'InternetAddress_Parse'. What do I bind it to?" The embedder provides a C++
method and it gets wired up appropriately like it is today.

## Proposal

Those examples covered all of the moving parts. Before we get into the details,
here's a quick summary:

 *  A function or member in a *canonical library* can be marked `external`.
    That declares it statically for tooling but delegates the implementation to
    elsewhere.

 *  The "elsewhere" can be an *external library* that is referenced by the
    canonical library. This Dart library provides concrete implementations of
    the external methods that get *patched* into the canonical library.

 *  A canonical library may use *if clauses* to link to multiple external
    libraries and the right one is chosen based on the configuration.

 *  An external library may have its own imports that are specific to a
    configuration.

 *  An external method may have an optional string literal that can be used by
    an implementation as it sees fit.

 *  If an external method isn't implemented by an external library, the host
    implementation can handle it how it wants.

Now we can get into the details of how these could work. This is still fairly
open-ended. My goal is to be able to subsume the existing uses of `native` and
patch files but I don't know all of the gory details of how those work yet. If
you do, please do help me refine this such that we can cover all of the
existing uses.

### Declaring external functions

We extend the grammar to allow a string literal at the end of an external
function declaration. Replace the existing spec for **declaration** with:

**declaration:**<br>
&emsp;&emsp;memberDeclaration |<br>
&emsp;&emsp;`external` memberDeclaration plainString?<br>
&emsp;&emsp;fieldDeclaration<br>
&emsp;&emsp;;

**memberDeclaration:**<br>
&emsp;&emsp;constantConstructorSignature (redirection | initializers)? |<br>
&emsp;&emsp;constructorSignature (redirection | initializers)? |<br>
&emsp;&emsp;`static`? getterSignature |<br>
&emsp;&emsp;`static`? setterSignature |<br>
&emsp;&emsp;operatorSignature |<br>
&emsp;&emsp;`static`? functionSignature |<br>
&emsp;&emsp;;

**fieldDeclaration:**<br>
&emsp;&emsp;`static` (`final` | `const`) type? staticFinalDeclarationList |<br>
&emsp;&emsp;`final` type? initializedIdentifierList |<br>
&emsp;&emsp;`static`? (`var` | type) initializedIdentifierList<br>
&emsp;&emsp;;

I'm guessing we don't want to allow interpolation inside the string literal,
but we also don't want to require `r` before the string, which leads to:

**plainString:**<br>
&emsp;&emsp;`'` (~(`'` | NEWLINE))* `'` |<br>
&emsp;&emsp;`"` (~(`"` | NEWLINE))* `"`<br>
&emsp;&emsp;;

And we can reuse that in **singleLineString**:

**singleLineString:**<br>
&emsp;&emsp;`"` stringContentDQ* `"` |<br>
&emsp;&emsp;`'` stringContentSQ* `'` |<br>
&emsp;&emsp;`r` plainString<br>
&emsp;&emsp;;

The `native` keyword is also used before classes to indicate that the class
itself has some custom implementation-specific backing storage or
implementation. To support that, we may also want to allow the `external`
keyword before a class:

**classDefinition:**<br>
&emsp;&emsp;metadata (`abstract`|`external`)? `class` identifier typeParameters? (superclass mixins?)? interfaces?<br>
&emsp;&emsp;`{` (metadata classMemberDefinition)* `}` |<br>
&emsp;&emsp;metadata `abstract`? `class` mixinApplicationClass<br>
&emsp;&emsp;;<br>

### Linking to external libraries

A canonical library can wire itself up with zero or more external libraries
using an external library directive:

**libraryDefinition:**<br>
&emsp;&emsp;scriptTag? libraryName? (externalLibrary|externalForLibrary)? importOrExport\* partDirective\* topLevelDefinition*<br>
&emsp;&emsp;;

**externalLibrary:**<br>
&emsp;&emsp;`external` `library` (uri | externalConditions)`;`<br>
&emsp;&emsp;;

If a *uri* is given, than that library is always chosen. Otherwise, one or more
conditional external libraries may be configured:

**externalConditions:**<br>
&emsp;&emsp;(`if` `(` expression `)` uri)+ (`else` uri)?<br>
&emsp;&emsp;;

*Note: I'm not strongly attached to this syntax. Break out your paint for the
bikeshed.*

Each *expression* must be a constant expression. They are evaluated essentially
the same as in [Lasse's configured imports proposal][config].

[config]: https://github.com/lrhn/dep-configured-imports/blob/master/DEP-configured-imports.md#semantics

*TODO: Specify this more precisely.*

The `if` clauses are evaluated in order. The first one that evaluates to `true`
has its URI chosen as the external library. If no `if` clause matches, the
`else` URI is used, if given. Otherwise, no external library is chosen and it
falls onto the implementation to decide how to handle the unpatched `external`
methods.

(It is not required for a library to have an `external library` directive in
order to declare `external` functions. This is useful for backwards compatibility and in cases where an `external` function is handled by the implementation and not an external library.)

This is the *only* way to reference an external library. It cannot be imported,
exported, or parted.

### Defining an external library

An external library is a library that contains an `external library for`
directive:

**externalForLibrary:**<br>
&emsp;&emsp;`external` `library` `for` uri`;`<br>
&emsp;&emsp;;

If library A has an `external library` directive with a URI referencing library
B, library B must have an `external library for` directive with a URI
referencing library A.

It is a compile error to import, export, or part a library that contains an
`external library for` directive.

Having URIs pointing in both directions is technically redundant. However, it
ensures that when starting static analysis from an external library, the tool
can correctly find the canonical library it is associated with.

### Merging an external library

This is the most complex corner of this proposal, and likely the part that will
need the most iteration. We need to decide how the external and canonical
libraries interact. We also want to statically analyze both libraries and give
the user early feedback if this process is unlikely to succeed.

Note that configuration-specific libraries do not add any complexity. At static
analysis time, we consider each external library independently. All that
matters is its relationship to its canonical library. At runtime, only a single
configuration will be chosen, so there is only a single canonical/external
library pair to merge.

The basic concepts are:

 *  Both the canonical and external libraries retain their original lexical
    scopes. Functions and members in each of those libraries are always
    resolved in the lexical scope in which they appear.

 *  For each patched class, *single* class is produced that contains the
    members of both the canonical and external library and that class is bound
    to its name in both libraries' namespaces. Explicit and implicit references
    to `this` in members of that class always refer to this merged class.

 *  Private names are considered part of the library's lexical scope. A merged
    class may contain private members from both the canonical and external
    library but members in each library each can only see their own private
    names.

Here's a more precise imperative specification of the process. Given a
canonical library C ("canonical") and an external library E ("external"), here
is what we do:

1.  For every top-level `external` function in C:
    1.  If a top-level function (including getters and setters) in E with the
        same name exists:
        1.  If the name does not refer to a function, or the function's type is
            not exactly the same as the type of the function in C, fail with a
            compile error.
        2.  Otherwise, replace the function in C with one that forwards to the
            function in E.
    2.  Else:
        1.  Do nothing. (This falls back to the existing behavior to let the
            platform inject an implementation.)
2.  For every class T ("type") in C where there is a class P ("patch") in E
    with the same name:
    1.  For every `external` member in T:
        1.  If a member with that name exists in P:
            2.  If the type of P's member is not exactly the same as T's, fail
                with a compile error.
            3.  Replace the member in T with the member in P. The body of the
                member retains its original lexical scope in E, but resolves
                `this` to be an instance of T. Likewise, `super` usage resolves
                to the superclass of T.
        2.  Else:
            1.  Do nothing. (This falls back to the existing behavior to let
                the platform inject an implementation.)
    2.  For every non-abstract member in P that we have not already handled:
        1.  If a member with that name exists in T, fail with a compile error.
        2.  Otherwise, add the member to T. The body of the member retains its
            original lexical scope in E, but resolves `this` to be an instance
            of T. Likewise, `super` usage resolves to the superclass of T.
    3.  Replace P and all references to P in E with T.

### Static analysis of libraries containing `external`

A library declaring `external` functions is analyzed like a normal library with
any external functions acting like normal declarations.

This is critical because it means the analyzer can work with libraries
containing external functions even if those functions are implemented in some
mechanism outside of the Dart platform. Since the external functions in the
canonical library do have static type signatures, that's enough to analyze a
program that calls them.

You might think we could also include added class members from an external
library when statically analyzing an canonical library. For example, given:

```dart
// canonical.dart
external library 'external.dart';

class C {}

// external.dart
external library for 'canonical.dart';

class C {
  added() { ... }
}

// main.dart
main() {
  new C().added(); // <-- Safe?
}
```

You might not expect any static warnings. However, this doesn't work in the
presence of multiple configuration-specific external libraries. One
configuration may add some member that another configuration does not. To avoid
that, only the members explicitly declared in the canonical library are
statically visible from the canonical library.

### Static analysis of an external library

The story for external libraries is a little different. Since any external
library only points to a *single* canonical library, we do know which members
the merged class will have *in the context of the external library*. That means
this should not have a static warning:

```dart
// canonical.dart
external library 'external.dart';

class C {
  fromCanonical() { ... }
}

// external.dart
external library for 'canonical.dart';

class C {}

test() {
  new C().fromCanonical(); // <-- OK.
}
```

When analyzing an external library, we replace any classes it defines with their merged versions.

## Alternatives

The existing ad-hoc solutions for `native` functions and patch files are the
main prior art here. They are less than an "alternative" than they are a
starting point for this proposal. Basically, we take those and polish them up
for end users.

The nice thing about having these is that they form an existence proof of the
workability of the proposal. If these features are powerful enough for our own
core, IO, and HTML libraries, they are likely powerful enough for end users
too.

In addition, there have been a number of attempts at solutions to the
"configuration-specific code" problem over the years. One other active proposal
is Lasse's [configured imports DEP][].

[configured imports dep]: https://github.com/lrhn/dep-configured-imports

One fundamental difference between the proposals is how configuration affects
the *static* structure of the program. With this proposal, the external
libraries do not affect global analysis. This encapsulates
configuration-specific differences within a single library. Lasse's proposal
allows different configured imports to expose a different public API.

This means analysis either has to try to do a multiway "union" of them to
provide a holistic view of all configurations simultaneously, or require the
user to select which configuration they are currently looking at.

## Implications and limitations

**TODO!**

## Deliverables

**TODO!**

### Language specification changes

**TODO!**

### A working implementation

**TODO!**

### Tests

**TODO!**

## Open questions

*   Does an external library have to annotate which classes and methods are
    patching things in the canonical library, or is name matching enough to
    indicate that?

*   How strict should we be about member collisions in a patched class? An
    error? Warning? If a warning, what are the runtime semantics?

*   Will an external library need access to the canonical library's private
    scope?

*   Do we need to allow string literals on `external` methods or can we just
    use metadata annotations in the VM like dart2js does?

## Patents rights

TC52, the Ecma technical committee working on evolving the open [Dart
standard][], operates under a royalty-free patent policy, [RFPP][] (PDF). This
means if the proposal graduates to being sent to TC52, you will have to sign
the Ecma TC52 [external contributer form][] and submit it to Ecma.

[dart standard]: http://www.ecma-international.org/publications/standards/Ecma-408.htm
[rfpp]: http://www.ecma-international.org/memento/TC52%20policy/Ecma%20Experimental%20TC52%20Royalty-Free%20Patent%20Policy.pdf
[external contributer form]: http://www.ecma-international.org/memento/TC52%20policy/Contribution%20form%20to%20TC52%20Royalty%20Free%20Task%20Group%20as%20a%20non-member.pdf
