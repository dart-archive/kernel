// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library kernel.transformations.closure_conversion;

import 'dart:collection' show
    Queue;

import '../ast.dart';
import '../core_types.dart';
import '../visitor.dart';
import '../frontend/accessors.dart';
import 'skip.dart';

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
///       Context copy() {
///         Context c = new Context(list.length);
///         c.parent = parent;
///         c.list.setRange(0, list.length, list);
///         return c;
///       }
///     }
///
/// Returns the mock.
Class mockUpContext(CoreTypes coreTypes, Program program) {
  ///     final List list;
  Field listField = new Field(
      new Name("list"), type: coreTypes.listClass.rawType, isFinal: true);
  Accessor listFieldAccessor =
      new ThisPropertyAccessor(listField.name, listField, null);

  ///     var parent;
  Field parentField = new Field(new Name("parent"));
  Accessor parentFieldAccessor =
      new ThisPropertyAccessor(parentField.name, parentField, parentField);

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
      listFieldAccessor.buildSimpleRead(),
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
      listFieldAccessor.buildSimpleRead(),
      new VariableAccessor(iParameter).buildSimpleRead(), null, null);
  Expression expression = accessor.buildAssignment(
      new VariableAccessor(valueParameter).buildSimpleRead(),
      voidContext: true);
  Procedure indexSet = new Procedure(new Name("[]="), ProcedureKind.Operator,
      new FunctionNode(new ExpressionStatement(expression),
          positionalParameters: <VariableDeclaration>[
              iParameter, valueParameter]));

  ///       Context copy() {
  ///         Context c = new Context(list.length);
  ///         c.parent = parent;
  ///         c.list.setRange(0, list.length, list);
  ///         return c;
  ///       }
  VariableDeclaration c = new VariableDeclaration(
      "c", initializer: new ConstructorInvocation(
          constructor,
          new Arguments(
              <Expression>[
                  new PropertyGet(listFieldAccessor.buildSimpleRead(),
                      new Name("length"))])));
  Accessor accessCParent = PropertyAccessor.make(
      new VariableGet(c), parentField.name, parentField, parentField);
  Accessor accessCList = PropertyAccessor.make(
      new VariableGet(c), listField.name, listField, null);
  List<Statement> statements = <Statement>[
      c,
      new ExpressionStatement(
          accessCParent.buildAssignment(
              parentFieldAccessor.buildSimpleRead(), voidContext: true)),
      new ExpressionStatement(
          new MethodInvocation(
              accessCList.buildSimpleRead(),
              new Name("setRange"),
              new Arguments(
                  <Expression>[
                      new IntLiteral(0),
                      new PropertyGet(
                          listFieldAccessor.buildSimpleRead(),
                          new Name("length")),
                      listFieldAccessor.buildSimpleRead()]))),
      new ReturnStatement(new VariableGet(c))];
  Procedure copy = new Procedure(new Name("copy"), ProcedureKind.Method,
      new FunctionNode(new Block(statements)));

  List<Procedure> procedures = <Procedure>[indexGet, indexSet, copy];

  Class contextClass = new Class(name: "Context",
      supertype: coreTypes.objectClass.rawType, constructors: [constructor],
      fields: fields, procedures: procedures);
  Library mock = new Library(
      Uri.parse("dart:mock"), name: "mock", classes: [contextClass]);
  program.libraries.add(mock);
  mock.parent = program;
  return contextClass;
}

Program transformProgram(Program program) {
  var captured = new CapturedVariables();
  captured.visitProgram(program);

  CoreTypes coreTypes = new CoreTypes(program);
  Class contextClass = mockUpContext(coreTypes, program);
  var convert = new ClosureConverter(coreTypes, captured, contextClass);
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
    Class contextClass = converter.contextClass;
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
  final Class contextClass;
  final Set<VariableDeclaration> capturedVariables;
  final Map<FunctionNode, Set<TypeParameter>> capturedTypeVariables;
  final Queue<FunctionNode> enclosingGenericFunctions =
      new Queue<FunctionNode>();

  /// Records place-holders for cloning contexts. See [visitForStatement].
  final Set<InvalidExpression> contextClonePlaceHolders =
      new Set<InvalidExpression>();

  Library currentLibrary;
  int closureCount = 0;
  Block _currentBlock;
  int _insertionIndex = 0;

  Context context;

  FunctionNode currentFunction;
  Class currentClass;

  /// Maps original type variable (aka type parameter) to a hoisted type
  /// variable.
  ///
  /// For example, consider:
  ///
  ///     class C<T> {
  ///       f() => (x) => x is T;
  ///     }
  ///
  /// This is currently converted to:
  ///
  ///    class C<T> {
  ///      f() => new Closure#0<T>();
  ///    }
  ///    class Closure#0<T_> implements Function {
  ///      call(x) => x is T_;
  ///    }
  ///
  /// In this example, `typeParameterMapping[T] == T_` when transforming the
  /// closure in `f`.
  Map<TypeParameter, TypeParameter> typeParameterMapping;

  ClosureConverter(
      this.coreTypes, CapturedVariables captured, this.contextClass)
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

  TreeNode visitClass(Class node) {
    if (node.name.startsWith("Closure#")) return node;
    currentClass = node;
    TreeNode result = super.visitClass(node);
    currentClass = null;
    return result;
  }

  TreeNode visitConstructor(Constructor node) {
    // TODO(ahe): Convert closures in constructors as well.
    return node;
  }

  Expression handleLocalFunction(FunctionNode function) {
    if (function.typeParameters.isNotEmpty) {
      enclosingGenericFunctions.addLast(function);
    }
    FunctionNode enclosingFunction = currentFunction;
    Map<TypeParameter, TypeParameter> enclosingTypeParameterMapping =
        typeParameterMapping;
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
        type: contextClass.rawType,
        isFinal: true);
    Context parent = context;
    context = context.toClosureContext(contextVariable);

    Set<TypeParameter> captured = capturedTypeVariables[currentFunction];
    List<TypeParameter> typeParameters;
    List<DartType> typeArguments;
    if (captured != null) {
      bool isCaptured(TypeParameter t) => captured.contains(t);
      List<TypeParameter> original = <TypeParameter>[];
      original.addAll(currentClass.typeParameters.where(isCaptured));
      for (FunctionNode generic in enclosingGenericFunctions) {
        if (generic == function) continue;
        original.addAll(generic.typeParameters.where(isCaptured));
      }
      assert(original.length == captured.length);
      typeParameters = new List<TypeParameter>.generate(
          captured.length, (int i) => new TypeParameter(original[i].name));
      typeArguments = new List<DartType>.generate(captured.length, (int i) {
        TypeParameter mappedTypeVariable = original[i];
        if (enclosingTypeParameterMapping != null) {
          mappedTypeVariable =
              enclosingTypeParameterMapping[mappedTypeVariable];
        }
        return new TypeParameterType(mappedTypeVariable);
      });
      typeParameterMapping = <TypeParameter, TypeParameter>{};
      for (int i = 0; i < original.length; i++) {
        typeParameterMapping[original[i]] = typeParameters[i];
      }
    } else {
      typeParameterMapping = null;
    }

    function.transformChildren(this);

    Expression result = addClosure(function, contextVariable, parent.expression,
        typeParameters, typeArguments);
    currentFunction = enclosingFunction;
    if (function.typeParameters.isNotEmpty) {
      enclosingGenericFunctions.removeLast();
    }
    typeParameterMapping = enclosingTypeParameterMapping;
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
      Expression accessContext,
      List<TypeParameter> typeParameters,
      List<DartType> typeArguments) {
    Class closureClass = new Class(
        name: 'Closure#${closureCount++}',
        supertype: coreTypes.objectClass.rawType,
        typeParameters: typeParameters,
        implementedTypes: <InterfaceType>[coreTypes.functionClass.rawType]);
    closureClass.addMember(
        new Field(new Name("note"), type: coreTypes.stringClass.rawType,
            initializer: new StringLiteral(
                "This is temporary. The VM doesn't need closure classes.")));
    Field contextField = new Field(
        new Name("context"), type: contextClass.rawType);
    closureClass.addMember(contextField);
    VariableDeclaration contextParameter = new VariableDeclaration(
        null, type: contextClass.rawType, isFinal: true);
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
    return new ConstructorInvocation(constructor,
        new Arguments(<Expression>[accessContext], types: typeArguments));
  }

  TreeNode visitProcedure(Procedure node) {
    // TODO(ahe): Delete this check, eventually all procedures should be
    // converted.
    if (!convertClosures(node)) return node;
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

    bool hasTypeVariables = node.function.typeParameters.isNotEmpty;
    if (hasTypeVariables) {
      enclosingGenericFunctions.addLast(node.function);
    }

    node.transformChildren(this);

    if (hasTypeVariables) {
      enclosingGenericFunctions.removeLast();
    }

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

    if (node.parent == currentFunction) return node;
    if (node.parent is Block) {
      // When returning null, the parent block will remove this node from its
      // list of statements.
      // TODO(ahe): I'd like to avoid testing on the parent pointer.
      return null;
    }
    throw "Unexpected parent for $node: ${node.parent.parent}";
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
      assert(typeParameterMapping.containsKey(node.parameter));
      return new TypeParameterType(typeParameterMapping[node.parameter]);
    } else {
      return node;
    }
  }

  VariableDeclaration getReplacementLoopVariable(VariableDeclaration variable) {
    VariableDeclaration newVariable = new VariableDeclaration(
        null, initializer: variable.initializer, type: variable.type)
        ..flags = variable.flags;
    variable.initializer = new VariableGet(newVariable);
    variable.initializer.parent = variable;
    return newVariable;
  }

  Expression cloneContext() {
    InvalidExpression placeHolder = new InvalidExpression();
    contextClonePlaceHolders.add(placeHolder);
    return placeHolder;
  }

  TreeNode visitInvalidExpression(InvalidExpression node) {
    return contextClonePlaceHolders.remove(node) ? context.clone() : node;
  }

  TreeNode visitForStatement(ForStatement node) {
    if (node.variables.any(capturedVariables.contains)) {
      // In Dart, loop variables are new variables on each iteration of the
      // loop. This is only observable when a loop variable is captured by a
      // closure, which is the situation we're in here. So we transform the
      // loop.
      //
      // Consider the following example, where `x` is `node.variables.first`,
      // and `#t1` is a temporary variable:
      //
      //     for (var x = 0; x < 10; x++) body;
      //
      // This is transformed to:
      //
      //     {
      //       var x = 0;
      //       for (; x < 10; clone-context, x++) body;
      //     }
      //
      // `clone-context` is a place-holder that will later be replaced by an
      // expression that clones the current closure context (see
      // [visitInvalidExpression]).
      List<Statement> statements = <Statement>[];
      statements.addAll(node.variables);
      statements.add(node);
      node.variables.clear();
      node.updates.insert(0, cloneContext());
      return new Block(statements).accept(this);
    }
    return super.visitForStatement(node);
  }

  TreeNode visitForInStatement(ForInStatement node) {
    if (capturedVariables.contains(node.variable)) {
      // In Dart, loop variables are new variables on each iteration of the
      // loop. This is only observable when the loop variable is captured by a
      // closure, so we need to transform the for-in loop when `node.variable`
      // is captured.
      //
      // Consider the following example, where `x` is `node.variable`, and
      // `#t1` is a temporary variable:
      //
      //     for (var x in expr) body;
      //
      // Notice that we can assume that `x` doesn't have an initializer based
      // on invariants in the Kernel AST. This is transformed to:
      //
      //     for (var #t1 in expr) { var x = #t1; body; }
      //
      // After this, we call super to apply the normal closure conversion to
      // the transformed for-in loop.
      VariableDeclaration variable = node.variable;
      VariableDeclaration newVariable = getReplacementLoopVariable(variable);
      node.variable = newVariable;
      newVariable.parent = node;
      node.body = new Block(<Statement>[variable, node.body]);
      node.body.parent = node;
    }
    return super.visitForInStatement(node);
  }
}

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
