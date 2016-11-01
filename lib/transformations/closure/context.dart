// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library kernel.transformations.closure.context;

import '../../ast.dart' show
    Arguments,
    Class,
    ConstructorInvocation,
    Expression,
    ExpressionStatement,
    IntLiteral,
    InterfaceType,
    MethodInvocation,
    Name,
    NullLiteral,
    PropertyGet,
    PropertySet,
    StringLiteral,
    Throw,
    VariableDeclaration,
    VariableGet,
    VariableSet;

import '../../frontend/accessors.dart' show
    IndexAccessor;

import 'converter.dart' show
    ClosureConverter;

abstract class Context {
  Expression get expression;

  void extend(VariableDeclaration variable, Expression value);
  void update(VariableDeclaration variable, Expression value) {
    throw "not supported $runtimeType";
  }

  Expression lookup(VariableDeclaration variable);
  Expression assign(VariableDeclaration variable, Expression value,
      {bool voidContext: false});

  Context toClosureContext(VariableDeclaration parameter);

  Expression clone() {
    return new Throw(
        new StringLiteral(
            "Context clone not implemented for ${runtimeType}"));
  }
}

class NoContext extends Context {
  final ClosureConverter converter;

  NoContext(this.converter);

  Expression get expression => new NullLiteral();

  void extend(VariableDeclaration variable, Expression value) {
    converter.context =
        new LocalContext(converter, this)..extend(variable, value);
  }

  Expression lookup(VariableDeclaration variable) {
    throw 'Unbound NoContext.lookup($variable)';
  }

  Expression assign(VariableDeclaration variable, Expression value,
      {bool voidContext: false}) {
    throw 'Unbound NoContext.assign($variable, ...)';
  }

  Context toClosureContext(VariableDeclaration parameter) {
    return new ClosureContext(converter, parameter,
                              <List<VariableDeclaration>>[]);
  }
}

class LocalContext extends Context {
  final ClosureConverter converter;
  final Context parent;
  final VariableDeclaration self;
  final IntLiteral size;
  final List<VariableDeclaration> variables = <VariableDeclaration>[];
  final Map<VariableDeclaration, Arguments> initializers =
      <VariableDeclaration, Arguments>{};

  LocalContext._internal(this.converter, this.parent, this.self, this.size);

  factory LocalContext(ClosureConverter converter, Context parent) {
    Class contextClass = converter.contextClass;
    assert(contextClass.constructors.length == 1);
    IntLiteral zero = new IntLiteral(0);
    VariableDeclaration declaration =
        new VariableDeclaration.forValue(
            new ConstructorInvocation(contextClass.constructors.first,
                                      new Arguments(<Expression>[zero])),
            type: new InterfaceType(contextClass));
    declaration.name = "#context";
    converter.insert(declaration);
    converter.insert(new ExpressionStatement(
        new PropertySet(new VariableGet(declaration),
                        new Name('parent'),
                        parent.expression)));

    return new LocalContext._internal(converter, parent, declaration, zero);
  }

  Expression get expression => new VariableGet(self);

  void extend(VariableDeclaration variable, Expression value) {
    Arguments arguments = new Arguments(
        <Expression>[new IntLiteral(variables.length), value]);
    converter.insert(
        new ExpressionStatement(
            new MethodInvocation(expression, new Name('[]='), arguments)));
    ++size.value;
    variables.add(variable);
    initializers[variable] = arguments;
  }

  void update(VariableDeclaration variable, Expression value) {
    Arguments arguments = initializers[variable];
    arguments.positional[1] = value;
    value.parent = arguments;
  }

  Expression lookup(VariableDeclaration variable) {
    var index = variables.indexOf(variable);
    return index == -1
        ? parent.lookup(variable)
        : new MethodInvocation(
              expression,
              new Name('[]'),
              new Arguments(<Expression>[new IntLiteral(index)]));
  }

  Expression assign(VariableDeclaration variable, Expression value,
      {bool voidContext: false}) {
    var index = variables.indexOf(variable);
    return index == -1
        ? parent.assign(variable, value, voidContext: voidContext)
        : IndexAccessor.make(expression, new IntLiteral(index), null, null)
            .buildAssignment(value, voidContext: voidContext);
  }

  Context toClosureContext(VariableDeclaration parameter) {
    List<List<VariableDeclaration>> variabless = <List<VariableDeclaration>>[];
    var current = this;
    while (current != null && current is! NoContext) {
      if (current is LocalContext) {
        variabless.add(current.variables);
        current = current.parent;
      } else if (current is ClosureContext) {
        variabless.addAll(current.variabless);
        current = null;
      }
    }
    return new ClosureContext(converter, parameter, variabless);
  }

  Expression clone() {
    self.isFinal = false;
    return new VariableSet(
        self, new MethodInvocation(
            new VariableGet(self), new Name("copy"), new Arguments.empty()));
  }
}

class ClosureContext extends Context {
  final ClosureConverter converter;
  final VariableDeclaration self;
  final List<List<VariableDeclaration>> variabless;

  ClosureContext(this.converter, this.self, this.variabless);

  Expression get expression => new VariableGet(self);

  void extend(VariableDeclaration variable, Expression value) {
    converter.context =
        new LocalContext(converter, this)..extend(variable, value);
  }

  Expression lookup(VariableDeclaration variable) {
    var context = expression;
    for (var variables in variabless) {
      var index = variables.indexOf(variable);
      if (index != -1) {
        return new MethodInvocation(
            context,
            new Name('[]'),
            new Arguments(<Expression>[new IntLiteral(index)]));
      }
      context = new PropertyGet(context, new Name('parent'));
    }
    throw 'Unbound ClosureContext.lookup($variable)';
  }

  Expression assign(VariableDeclaration variable, Expression value,
      {bool voidContext: false}) {
    var context = expression;
    for (var variables in variabless) {
      var index = variables.indexOf(variable);
      if (index != -1) {
        return IndexAccessor.make(context, new IntLiteral(index), null, null)
            .buildAssignment(value, voidContext: voidContext);
      }
      context = new PropertyGet(context, new Name('parent'));
    }
    throw 'Unbound ClosureContext.lookup($variable)';
  }

  Context toClosureContext(VariableDeclaration parameter) {
    return new ClosureContext(converter, parameter, variabless);
  }
}
