// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library kernel.transformations.closure.converter;

import 'dart:collection' show
    Queue;

import '../../ast.dart' show
    Arguments,
    Block,
    BlockExpression,
    Class,
    Constructor,
    ConstructorInvocation,
    DartType,
    DartTypeVisitor,
    EmptyStatement,
    Expression,
    ExpressionStatement,
    Field,
    FieldInitializer,
    ForInStatement,
    ForStatement,
    FunctionDeclaration,
    FunctionExpression,
    FunctionNode,
    InferredValue,
    Initializer,
    InterfaceType,
    InvalidExpression,
    Library,
    LocalInitializer,
    Member,
    Name,
    NamedExpression,
    NullLiteral,
    Procedure,
    ProcedureKind,
    PropertyGet,
    ReturnStatement,
    Statement,
    StaticGet,
    StaticInvocation,
    StringLiteral,
    ThisExpression,
    Transformer,
    TreeNode,
    TypeParameter,
    TypeParameterType,
    VariableDeclaration,
    VariableGet,
    VariableSet,
    transformList;

import '../../clone.dart' show
    CloneVisitor;

import '../../core_types.dart' show
    CoreTypes;

import '../../visitor.dart' show
    DartTypeVisitor,
    Transformer;

import 'context.dart' show
    Context,
    NoContext;

import 'info.dart' show
    ClosureInfo;

import 'skip.dart' show
    convertClosures;

class ClosureConverter extends Transformer with DartTypeVisitor<DartType> {
  final CoreTypes coreTypes;
  final Class contextClass;
  final Set<VariableDeclaration> capturedVariables;
  final Map<FunctionNode, Set<TypeParameter>> capturedTypeVariables;
  final Map<FunctionNode, VariableDeclaration> thisAccess;
  final Map<FunctionNode, String> localNames;
  final Queue<FunctionNode> enclosingGenericFunctions =
      new Queue<FunctionNode>();

  /// Records place-holders for cloning contexts. See [visitForStatement].
  final Set<InvalidExpression> contextClonePlaceHolders =
      new Set<InvalidExpression>();

  Library currentLibrary;
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
      this.coreTypes, ClosureInfo info, this.contextClass)
      : this.capturedVariables = info.variables,
        this.capturedTypeVariables = info.typeVariables,
        this.thisAccess = info.thisAccess,
        this.localNames = info.localNames;

  FunctionNode currentMember;

  bool get isOuterMostContext {
    return currentFunction == null || currentMember == currentFunction;
  }

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

    VariableDeclaration contextVariable = new VariableDeclaration(
        "#contextParameter", type: contextClass.rawType, isFinal: true);
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
          captured.length, (int i) => new TypeParameter(
              original[i].name, coreTypes.objectClass.rawType));
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
    Field contextField = new Field(
        new Name("context"), type: contextClass.rawType);
    Class closureClass = createClosureClass(function, fields: [contextField],
        typeParameters: typeParameters);
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
    return new ConstructorInvocation(closureClass.constructors.single,
        new Arguments(<Expression>[accessContext], types: typeArguments));
  }

  TreeNode visitField(Field node) {
    context = new NoContext(this);
    node = super.visitField(node);
    context = null;
    return node;
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

    currentMember = node.function;

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

    VariableDeclaration self = thisAccess[currentMember];
    if (self != null) {
      context.extend(self, new ThisExpression());
    }

    node.transformChildren(this);

    if (hasTypeVariables) {
      enclosingGenericFunctions.removeLast();
    }

    _currentBlock = null;
    _insertionIndex = 0;
    context = null;
    currentMember = null;
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
        variable.name, initializer: variable.initializer,
        type: variable.type)
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

  TreeNode visitThisExpression(ThisExpression node) {
    return isOuterMostContext
        ? node : context.lookup(thisAccess[currentMember]);
  }

  TreeNode visitStaticGet(StaticGet node) {
    Member target = node.target;
    if (target is Procedure && target.kind == ProcedureKind.Method) {
      Expression expression = getTearOffExpression(node.target);
      expression.transformChildren(this);
      return expression;
    }
    return super.visitStaticGet(node);
  }

  /// Creates a closure that will invoke [procedure].
  Expression getTearOffExpression(Procedure procedure) {
    // TODO(ahe): Implement instance tear-offs.
    assert(!procedure.isInstanceMember);
    Class closureClass = createClosureClass(procedure.function);
    closureClass.addMember(
        new Procedure(new Name("call"), ProcedureKind.Method,
            forwardFunction(procedure)));
    currentLibrary.addClass(closureClass);
    return new ConstructorInvocation(
        closureClass.constructors.single, new Arguments.empty());
  }

  /// Creates a function that has the same signature as `procedure.function`
  /// and which forwards all arguments to `procedure`.
  FunctionNode forwardFunction(Procedure procedure) {
    FunctionNode function = procedure.function;
    CloneVisitor cloner = new CloneVisitor();
    List<TypeParameter> typeParameters =
        function.typeParameters.map(cloner.clone).toList();
    List<VariableDeclaration> positionalParameters =
        function.positionalParameters.map(cloner.clone).toList();
    List<VariableDeclaration> namedParameters =
        function.namedParameters.map(cloner.clone).toList();
    // TODO(ahe): Clone or copy inferredReturnValue?
    InferredValue inferredReturnValue = null;

    List<DartType> types = typeParameters.map(
        (TypeParameter parameter) => new TypeParameterType(parameter)).toList();
    List<Expression> positional = positionalParameters.map(
        (VariableDeclaration parameter) => new VariableGet(parameter)).toList();
    List<NamedExpression> named = namedParameters.map(
        (VariableDeclaration parameter) {
          return new NamedExpression(
              parameter.name, new VariableGet(parameter));
        }).toList();

    Arguments arguments = new Arguments(positional, types: types, named: named);
    return new FunctionNode(
        new ReturnStatement(new StaticInvocation(procedure, arguments)),
        typeParameters: typeParameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
        requiredParameterCount: function.requiredParameterCount,
        returnType: function.returnType,
        inferredReturnValue: inferredReturnValue);
  }

  Class createClosureClass(FunctionNode function,
      {List<Field> fields, List<TypeParameter> typeParameters}) {
    Class closureClass = new Class(
        name: 'Closure#${localNames[function]}',
        supertype: coreTypes.objectClass.rawType,
        typeParameters: typeParameters,
        implementedTypes: <InterfaceType>[coreTypes.functionClass.rawType]);
    addClosureClassNote(closureClass);

    List<VariableDeclaration> parameters = <VariableDeclaration>[];
    List<Initializer> initializers = <Initializer>[];
    for (Field field in fields ?? const <Field>[]) {
      closureClass.addMember(field);
      VariableDeclaration parameter = new VariableDeclaration(
          field.name.name, type: field.type, isFinal: true);
      parameters.add(parameter);
      initializers.add(new FieldInitializer(field, new VariableGet(parameter)));
    }

    closureClass.addMember(
        new Constructor(
            new FunctionNode(
                new EmptyStatement(), positionalParameters: parameters),
            name: new Name(""),
            initializers: initializers));

    return closureClass;
  }

  // TODO(ahe): Remove this method when we don't generate closure classes
  // anymore.
  void addClosureClassNote(Class closureClass) {
    closureClass.addMember(
        new Field(new Name("note"), type: coreTypes.stringClass.rawType,
            initializer: new StringLiteral(
                "This is temporary. The VM doesn't need closure classes.")));
  }
}
