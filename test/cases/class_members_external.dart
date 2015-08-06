String _value;

class Foo {
  String method(String arg) => "$arg method";

  String get getter => _value;

  void set setter(String value) {
    _value = value;
  }

  String operator +(String other) => "foo + $other";
}
