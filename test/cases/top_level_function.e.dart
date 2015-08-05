//external: "top_level_function_external.dart"
library top_level_function.e.dart;

main() {
  function("string", 123);
}

external function(String a, int b);
// expect: patched string 123