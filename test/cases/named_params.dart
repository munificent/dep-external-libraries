//external: "named_params_external.dart"
library named_params;

main() {
  function(a: "string", b: 123); // expect: patched string 123
}

external function({String a, int b});
