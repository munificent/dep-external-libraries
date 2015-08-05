//external: "named_params_external.dart"
library named_params.e.dart;

main() {
  function(a: "string", b: 123);
}

external function({String a, int b});
// expect: patched string 123