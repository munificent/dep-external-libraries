//external: "top_level_function_external.dart"
library top_level_function;

main() {
  function("string", 123); // expect: patched string 123
}

external function(String a, int b);
