// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library kernel.transformations.closure.substitution;

import '../../ast.dart' show
    Expression,
    Transformer,
    TreeNode,
    VariableDeclaration,
    VariableGet,
    VariableSet;

import '../../visitor.dart' show
    Transformer;

class Substitution extends Transformer {
  final Map<VariableDeclaration, VariableDeclaration> substitution =
      <VariableDeclaration, VariableDeclaration>{};

  List<VariableDeclaration> get newVariables => substitution.values.toList();

  void operator[]= (VariableDeclaration key, VariableDeclaration value) {
    substitution[key] = value;
  }

  VariableDeclaration operator[] (VariableDeclaration key) => substitution[key];

  TreeNode call(Expression node) => node.accept(this);

  TreeNode visitVariableGet(VariableGet node) {
    VariableDeclaration newVariable = substitution[node.variable];
    if (newVariable != null) {
      node = new VariableGet(newVariable, node.promotedType);
    }
    return super.visitVariableGet(node);
  }

  TreeNode visitVariableSet(VariableSet node) {
    VariableDeclaration newVariable = substitution[node.variable];
    if (newVariable != null) {
      node = new VariableSet(newVariable, node.value);
    }
    return super.visitVariableSet(node);
  }
}
