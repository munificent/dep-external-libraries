// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dep_external_libraries.src.ast;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/src/generated/ast.dart';

/// A tiny utility class for creating blobs of AST nodes from source strings.
class Ast {
  static FunctionBody exprBody(String code) {
    var unit = parseCompilationUnit("main() => $code;");
    var main = unit.declarations.first as FunctionDeclaration;
    return main.functionExpression.body;
  }

  static Directive directive(String code) {
    var unit = parseCompilationUnit(code);
    return unit.directives.first;
  }

  static Statement stmt(String code) {
    var unit = parseCompilationUnit("main() { $code }");
    var main = unit.declarations.first as FunctionDeclaration;
    var body = main.functionExpression.body as BlockFunctionBody;
    return body.block.statements.first;
  }
}
