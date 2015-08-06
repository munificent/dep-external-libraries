//external: "class_members_external.dart"
library class_members;

main() {
  var foo = new Foo();

  print(foo.method("foo")); // expect: foo method
  foo.setter = "set value";
  print(foo.getter); // expect: set value
  print(foo + "rhs"); // expect: foo + rhs
}

class Foo {
  external String method(String arg);
  external String get getter;
  external void set setter(String value);
  external String operator +(String other);
}
