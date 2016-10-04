// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library kernel.transformations.closure_conversion;

import '../ast.dart';
import '../core_types.dart';
import '../visitor.dart';
import '../frontend/accessors.dart';

/// Extend the program with this mock:
///
///     class Context {
///       final List list;
///       var parent;
///       Context(int i) : list = new List(i);
///       operator[] (int i) => list[i];
///       operator[]= (int i, value) {
///         list[i] = value;
///       }
///     }
CoreTypes mockUpContext(Program program) {
  CoreTypes coreTypes = new CoreTypes(program);

  ///     final List list;
  Field listField = new Field(
      new Name("list"), type: coreTypes.listClass.rawType, isFinal: true);

  ///     var parent;
  Field parentField = new Field(new Name("parent"));

  List<Field> fields = <Field>[listField, parentField];

  ///     Context(int i) : list = new List(i);
  VariableDeclaration iParameter = new VariableDeclaration(
      "i", type: coreTypes.intClass.rawType, isFinal: true);
  Constructor constructor = new Constructor(
      new FunctionNode(new EmptyStatement(),
          positionalParameters: <VariableDeclaration>[iParameter]),
      name: new Name(""),
      initializers: <Initializer>[
            new FieldInitializer(
                listField, new StaticInvocation(
                    coreTypes.listClass.procedures.first,
                    new Arguments(
                        <Expression>[
                            new VariableAccessor(iParameter)
                                .buildSimpleRead()])))]);

  ///     operator[] (int i) => list[i];
  iParameter = new VariableDeclaration(
      "i", type: coreTypes.intClass.rawType, isFinal: true);
  Accessor accessor = IndexAccessor.make(
      new ThisPropertyAccessor(
          listField.name, listField, listField).buildSimpleRead(),
      new VariableAccessor(iParameter).buildSimpleRead(),
      null, null);
  Procedure indexGet = new Procedure(new Name("[]"), ProcedureKind.Operator,
      new FunctionNode(new ReturnStatement(accessor.buildSimpleRead()),
          positionalParameters: <VariableDeclaration>[iParameter]));

  ///     operator[]= (int i, value) {
  ///       list[i] = value;
  ///     }
  iParameter = new VariableDeclaration(
      "i", type: coreTypes.intClass.rawType, isFinal: true);
  VariableDeclaration valueParameter = new VariableDeclaration(
      "value", isFinal: true);
  accessor = IndexAccessor.make(
      new ThisPropertyAccessor(
          listField.name, listField, listField).buildSimpleRead(),
      new VariableAccessor(iParameter).buildSimpleRead(), null, null);
  Expression expression = accessor.buildAssignment(
      new VariableAccessor(valueParameter).buildSimpleRead(),
      voidContext: true);
  Procedure indexSet = new Procedure(new Name("[]="), ProcedureKind.Operator,
      new FunctionNode(new ExpressionStatement(expression),
          positionalParameters: <VariableDeclaration>[
              iParameter, valueParameter]));

  List<Procedure> procedures = <Procedure>[indexGet, indexSet];

  Class contextClass = new Class(name: "Context",
      supertype: coreTypes.objectClass.rawType, constructors: [constructor],
      fields: fields, procedures: procedures);
  Library mock = new Library(
      Uri.parse("dart:mock"), name: "mock", classes: [contextClass]);
  program.libraries.add(mock);
  mock.parent = program;
  coreTypes.internalContextClass = contextClass;
  return coreTypes;
}

Program transformProgram(Program program) {
  var captured = new CapturedVariables();
  captured.visitProgram(program);

  var convert = new ClosureConverter(mockUpContext(program), captured);
  return convert.visitProgram(program);
}

class CapturedVariables extends RecursiveVisitor {
  FunctionNode _currentFunction;
  final Map<VariableDeclaration, FunctionNode> _function =
      <VariableDeclaration, FunctionNode>{};

  final Set<VariableDeclaration> variables = new Set<VariableDeclaration>();

  final Map<FunctionNode, Set<TypeParameter>> typeVariables =
      <FunctionNode, Set<TypeParameter>>{};

  FunctionNode currentMember;

  bool get isOuterMostContext {
    return _currentFunction == null || currentMember == _currentFunction;
  }

  visitConstructor(Constructor node) {
    currentMember = node.function;
    super.visitConstructor(node);
    currentMember = null;
  }

  visitProcedure(Procedure node) {
    currentMember = node.function;
    super.visitProcedure(node);
    currentMember = null;
  }

  visitFunctionNode(FunctionNode node) {
    var saved = _currentFunction;
    _currentFunction = node;
    node.visitChildren(this);
    _currentFunction = saved;
    Set<TypeParameter> capturedTypeVariables = typeVariables[node];
    if (capturedTypeVariables != null && !isOuterMostContext) {
      // Propagate captured type variables to enclosing function.
      typeVariables
          .putIfAbsent(_currentFunction, () => new Set<TypeParameter>())
          .addAll(capturedTypeVariables);
    }
  }

  visitVariableDeclaration(VariableDeclaration node) {
    _function[node] = _currentFunction;
    node.visitChildren(this);
  }

  visitVariableGet(VariableGet node) {
    if (_function[node.variable] != _currentFunction) {
      variables.add(node.variable);
    }
    node.visitChildren(this);
  }

  visitVariableSet(VariableSet node) {
    if (_function[node.variable] != _currentFunction) {
      variables.add(node.variable);
    }
    node.visitChildren(this);
  }

  visitTypeParameterType(TypeParameterType node) {
    if (!isOuterMostContext) {
      typeVariables
          .putIfAbsent(_currentFunction, () => new Set<TypeParameter>())
          .add(node.parameter);
    }
  }
}

abstract class Context {
  Expression get expression;

  void extend(VariableDeclaration variable, Expression value);
  void update(VariableDeclaration variable, Expression value) {
    throw "not supported $runtimeType";
  }

  Expression lookup(VariableDeclaration variable);
  Expression assign(VariableDeclaration variable, Expression value);

  Context toClosureContext(VariableDeclaration parameter);
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

  Expression assign(VariableDeclaration variable, Expression value) {
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
    Class contextClass = converter.coreTypes.internalContextClass;
    assert(contextClass.constructors.length == 1);
    IntLiteral zero = new IntLiteral(0);
    VariableDeclaration declaration =
        new VariableDeclaration.forValue(
            new ConstructorInvocation(contextClass.constructors.first,
                                      new Arguments(<Expression>[zero])),
            type: new InterfaceType(contextClass));
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

  Expression assign(VariableDeclaration variable, Expression value) {
    var index = variables.indexOf(variable);
    return index == -1
        ? parent.assign(variable, value)
        : new MethodInvocation(
              expression,
              new Name('[]='),
              new Arguments(<Expression>[new IntLiteral(index), value]));
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
      } else if (current is LoopContext) {
        // TODO.
        current = current.parent;
      }
    }
    return new ClosureContext(converter, parameter, variabless);
  }
}

class LoopContext {
  final ClosureConverter converter;
  final Context parent;

  LoopContext(this.converter, this.parent);

  void extend(VariableDeclaration variable, Expression value) {
    converter.context =
        new LocalContext(converter, parent)..extend(variable, value);
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

  Expression assign(VariableDeclaration variable, Expression value) {
    var context = expression;
    for (var variables in variabless) {
      var index = variables.indexOf(variable);
      if (index != -1) {
        return new MethodInvocation(
            context,
            new Name('[]='),
            new Arguments(<Expression>[new IntLiteral(index), value]));
      }
      context = new PropertyGet(context, new Name('parent'));
    }
    throw 'Unbound ClosureContext.lookup($variable)';
  }

  Context toClosureContext(VariableDeclaration parameter) {
    return new ClosureContext(converter, parameter, variabless);
  }
}

class ClosureConverter extends Transformer with DartTypeVisitor<DartType> {
  final CoreTypes coreTypes;
  final Set<VariableDeclaration> capturedVariables;
  final Map<FunctionNode, Set<TypeParameter>> capturedTypeVariables;

  Library currentLibrary;
  int closureCount = 0;
  Block _currentBlock;
  int _insertionIndex = 0;

  Context context;

  FunctionNode currentFunction;

  ClosureConverter(this.coreTypes, CapturedVariables captured)
      : this.capturedVariables = captured.variables,
        this.capturedTypeVariables = captured.typeVariables;

  void insert(Statement statement) {
    _currentBlock.statements.insert(_insertionIndex++, statement);
    statement.parent = _currentBlock;
  }

  TreeNode saveContext(TreeNode f()) {
    Block savedBlock = _currentBlock;
    int savedIndex = _insertionIndex;
    Context savedContext = context;
    try {
      return f();
    } finally {
      _currentBlock = savedBlock;
      _insertionIndex = savedIndex;
      context = savedContext;
    }
  }

  TreeNode visitLibrary(Library node) {
    currentLibrary = node;
    return super.visitLibrary(node);
  }

  TreeNode visitConstructor(Constructor node) {
    // TODO(ahe): Convert closures in constructors as well.
    return node;
  }

  Expression handleLocalFunction(FunctionNode function) {
    FunctionNode savedCurrentFunction = currentFunction;
    currentFunction = function;
    Statement body = function.body;
    assert(body != null);

    if (body is Block) {
      _currentBlock = body;
    } else {
      _currentBlock = new Block(<Statement>[body]);
      function.body = body.parent = _currentBlock;
    }
    _insertionIndex = 0;

    VariableDeclaration contextVariable = new VariableDeclaration(null,
        type: coreTypes.internalContextClass.rawType,
        isFinal: true);
    Context parent = context;
    context = context.toClosureContext(contextVariable);

    function.transformChildren(this);

    Expression result =
        addClosure(function, contextVariable, parent.expression);
    currentFunction = savedCurrentFunction;
    return result;
  }

  TreeNode visitFunctionDeclaration(FunctionDeclaration node) {
    /// Is this closure itself captured by a closure?
    bool isCaptured = capturedVariables.contains(node.variable);
    if (isCaptured) {
      context.extend(node.variable, new InvalidExpression());
    }
    Context parent = context;
    return saveContext(() {
      Expression expression = handleLocalFunction(node.function);

      if (isCaptured) {
        parent.update(node.variable, expression);
        return null;
      } else {
        node.variable.initializer = expression;
        expression.parent = node.variable;
        return node.variable;
      }
    });
  }

  TreeNode visitFunctionExpression(FunctionExpression node) => saveContext(() {
    return handleLocalFunction(node.function);
  });

  /// Add a new class to the current library that looks like this:
  ///
  ///     class Closure#0 extends core::Object implements core::Function {
  ///       field _in::Context context;
  ///       constructor •(final _in::Context #t1) → dynamic
  ///         : self::Closure 0::context = #t1
  ///         ;
  ///       method call(/* The parameters of [function] */) → dynamic {
  ///         /// #t2 is [contextVariable].
  ///         final _in::Context #t2 = this.{self::Closure#0::context};
  ///         /* The body of [function]. */
  ///       }
  ///     }
  ///
  /// Returns a constructor call to invoke the above constructor.
  ///
  /// TODO(ahe): We shouldn't create a class for each closure. Instead we turn
  /// [function] into a top-level function and use the Dart VM's mechnism for
  /// closures.
  Expression addClosure(
      FunctionNode function,
      VariableDeclaration contextVariable,
      Expression accessContext) {
    Class closureClass = new Class(
        name: 'Closure#${closureCount++}',
        supertype: coreTypes.objectClass.rawType,
        implementedTypes: <InterfaceType>[coreTypes.functionClass.rawType]);
    closureClass.addMember(
        new Field(new Name("note"), type: coreTypes.stringClass.rawType,
            initializer: new StringLiteral(
                "This is temporary. The VM doesn't need closure classes.")));
    Field contextField = new Field(new Name("context"),
        type: coreTypes.internalContextClass.rawType);
    closureClass.addMember(contextField);
    VariableDeclaration contextParameter =
        new VariableDeclaration(null,
            type: coreTypes.internalContextClass.rawType,
            isFinal: true);
    Constructor constructor = new Constructor(
        new FunctionNode(new EmptyStatement(),
            positionalParameters: <VariableDeclaration>[contextParameter]),
        name: new Name(""),
        initializers: <Initializer>[
            new FieldInitializer(
                contextField, new VariableGet(contextParameter))]);
    closureClass.addMember(constructor);
    closureClass.addMember(
        new Procedure(new Name("call"), ProcedureKind.Method, function));
    currentLibrary.addClass(closureClass);
    List<Statement> statements = <Statement>[contextVariable];
    Statement body = function.body;
    if (body is Block) {
      statements.addAll(body.statements);
    } else {
      statements.add(body);
    }
    function.body = new Block(statements);
    function.body.parent = function;
    contextVariable.initializer = new BlockExpression(
        new Block(<Statement>[new ExpressionStatement(new StringLiteral(
            "This is a temporary solution. "
            "In the VM, this will become an additional parameter."))]),
        new PropertyGet(new ThisExpression(), contextField.name, contextField));

    contextVariable.initializer.parent = contextVariable;
    return new ConstructorInvocation(
        constructor, new Arguments(<Expression>[accessContext]));
  }

  TreeNode visitProcedure(Procedure node) {
    assert(_currentBlock == null);
    assert(_insertionIndex == 0);
    assert(context == null);

    Statement body = node.function.body;
    if (body == null) return node;

    // Ensure that the body is a block which becomes the current block.
    if (body is Block) {
      _currentBlock = body;
    } else {
      _currentBlock = new Block(<Statement>[body]);
      node.function.body = body.parent = _currentBlock;
    }
    _insertionIndex = 0;

    // Start with no context.  This happens after setting up _currentBlock
    // so statements can be emitted into _currentBlock if necessary.
    context = new NoContext(this);

    node.transformChildren(this);

    _currentBlock = null;
    _insertionIndex = 0;
    context = null;
    return node;
  }

  TreeNode visitLocalInitializer(LocalInitializer node) {
    assert(!capturedVariables.contains(node.variable));
    node.transformChildren(this);
    return node;
  }

  TreeNode visitFunctionNode(FunctionNode node) {
    transformList(node.typeParameters, this, node);

    void extend(VariableDeclaration parameter) {
      context.extend(parameter, new VariableGet(parameter));
    }
    // TODO: Can parameters contain initializers (e.g., for optional ones) that
    // need to be closure converted?
    node.positionalParameters.where(capturedVariables.contains).forEach(extend);
    node.namedParameters.where(capturedVariables.contains).forEach(extend);

    assert(node.body != null);
    node.body = node.body.accept(this);
    node.body.parent = node;
    return node;
  }

  TreeNode visitBlock(Block node) => saveContext(() {
    if (_currentBlock != node) {
      _currentBlock = node;
      _insertionIndex = 0;
    }

    while (_insertionIndex < _currentBlock.statements.length) {
      assert(_currentBlock == node);

      var original = _currentBlock.statements[_insertionIndex];
      var transformed = original.accept(this);
      assert(_currentBlock.statements[_insertionIndex] == original);
      if (transformed == null) {
        _currentBlock.statements.removeAt(_insertionIndex);
      } else {
        _currentBlock.statements[_insertionIndex++] = transformed;
        transformed.parent = _currentBlock;
      }
    }

    return node;
  });

  TreeNode visitVariableDeclaration(VariableDeclaration node) {
    node.transformChildren(this);

    if (!capturedVariables.contains(node)) return node;
    context.extend(node, node.initializer ?? new NullLiteral());

    // TODO(ahe): Return null here when the parent has been correctly
    // rewritten. So far, only for-in is known to use this return value.
    return new VariableDeclaration(null, initializer: new InvalidExpression());
  }

  TreeNode visitVariableGet(VariableGet node) {
    return capturedVariables.contains(node.variable)
        ? context.lookup(node.variable)
        : node;
  }

  TreeNode visitVariableSet(VariableSet node) {
    node.transformChildren(this);

    return capturedVariables.contains(node.variable)
        ? context.assign(node.variable, node.value)
        : node;
  }

  DartType visitDartType(DartType node) => node.accept(this);

  DartType defaultDartType(DartType node) => node;

  DartType visitInterfaceType(InterfaceType node) {
    List<DartType> typeArguments;
    for (int i = 0; i < node.typeArguments.length; i++) {
      DartType argument = node.typeArguments[i];
      DartType rewritten = argument.accept(this);
      if (argument != rewritten) {
        if (typeArguments == null) {
          typeArguments = new List<DartType>.from(node.typeArguments);
        }
        typeArguments[i] = rewritten;
      }
    }
    if (typeArguments == null) {
      return node;
    } else {
      return new InterfaceType(node.classNode, typeArguments);
    }
  }

  DartType visitTypeParameterType(TypeParameterType node) {
    if (currentFunction == null) return node;
    Set<TypeParameter> captured = capturedTypeVariables[currentFunction];
    if (captured != null) {
      assert(captured.contains(node.parameter));
      // TODO(ahe): Rewrite type parameters instead.
      return new DynamicType();
    } else {
      return node;
    }
  }
}
