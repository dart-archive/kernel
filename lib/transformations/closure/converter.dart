// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library kernel.transformations.closure.converter;

import '../../ast.dart' show
    Arguments,
    Block,
    BlockExpression,
    Catch,
    Class,
    Constructor,
    ConstructorInvocation,
    DartType,
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
    InvocationExpression,
    Library,
    LocalInitializer,
    Member,
    MethodInvocation,
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

import '../../frontend/accessors.dart' show
    VariableAccessor;

import '../../clone.dart' show
    CloneVisitor;

import '../../core_types.dart' show
    CoreTypes;

import '../../type_algebra.dart' show
    substitute;

import 'clone_without_body.dart' show
    CloneWithoutBody;

import 'context.dart' show
    Context,
    NoContext;

import 'info.dart' show
    ClosureInfo;

class ClosureConverter extends Transformer {
  final CoreTypes coreTypes;
  final Class contextClass;
  final Set<VariableDeclaration> capturedVariables;
  final Map<FunctionNode, Set<TypeParameter>> capturedTypeVariables;
  final Map<FunctionNode, VariableDeclaration> thisAccess;
  final Map<FunctionNode, String> localNames;

  /// Records place-holders for cloning contexts. See [visitForStatement].
  final Set<InvalidExpression> contextClonePlaceHolders =
      new Set<InvalidExpression>();

  /// Maps the names of all instance methods that may be torn off (aka
  /// implicitly closurized) to `${name.name}#get`.
  final Map<Name, Name> tearOffGetterNames;

  final CloneVisitor cloner = new CloneWithoutBody();

  /// New members to add to [currentLibrary] after it has been
  /// transformed. These members will not be transformed themselves.
  final List<TreeNode> newLibraryMembers = <TreeNode>[];

  /// New members to add to [currentClass] after it has been transformed. These
  /// members will not be transformed themselves.
  final List<Member> newClassMembers = <Member>[];

  Library currentLibrary;

  Class currentClass;

  Member currentMember;

  FunctionNode currentMemberFunction;

  FunctionNode currentFunction;

  Block _currentBlock;

  int _insertionIndex = 0;

  Context context;

  /// Maps original type variable (aka type parameter) to a hoisted type
  /// variable type.
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
  /// In this example, `typeSubstitution[T].parameter == T_` when transforming
  /// the closure in `f`.
  Map<TypeParameter, DartType> typeSubstitution =
      const <TypeParameter, DartType>{};

  ClosureConverter(
      this.coreTypes, ClosureInfo info, this.contextClass)
      : this.capturedVariables = info.variables,
        this.capturedTypeVariables = info.typeVariables,
        this.thisAccess = info.thisAccess,
        this.localNames = info.localNames,
        this.tearOffGetterNames = info.tearOffGetterNames;

  bool get isOuterMostContext {
    return currentFunction == null || currentMemberFunction == currentFunction;
  }

  String get currentFileUri {
    if (currentMember is Constructor) return currentClass.fileUri;
    if (currentMember is Field) return (currentMember as Field).fileUri;
    if (currentMember is Procedure) return (currentMember as Procedure).fileUri;
    throw "No file uri";
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
    assert(newLibraryMembers.isEmpty);
    if (node == contextClass.enclosingLibrary) return node;
    currentLibrary = node;
    node = super.visitLibrary(node);
    for (TreeNode member in newLibraryMembers) {
      if (member is Class) {
        node.addClass(member);
      } else {
        node.addMember(member);
      }
    }
    newLibraryMembers.clear();
    currentLibrary = null;
    return node;
  }

  TreeNode visitClass(Class node) {
    assert(newClassMembers.isEmpty);
    currentClass = node;
    node = super.visitClass(node);
    newClassMembers.forEach(node.addMember);
    newClassMembers.clear();
    currentClass = null;
    return node;
  }

  TreeNode visitConstructor(Constructor node) {
    // TODO(ahe): Convert closures in constructors as well.
    return node;
  }

  Expression handleLocalFunction(FunctionNode function) {
    FunctionNode enclosingFunction = currentFunction;
    Map<TypeParameter, DartType> enclosingTypeSubstitution =
        typeSubstitution;
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
    context = context.toNestedContext(new VariableAccessor(contextVariable));

    Set<TypeParameter> captured = capturedTypeVariables[currentFunction];
    if (captured != null) {
      typeSubstitution = copyTypeVariables(captured);
    } else {
      typeSubstitution = const <TypeParameter, DartType>{};
    }

    function.transformChildren(this);

    Expression result = addClosure(function, contextVariable, parent.expression,
        typeSubstitution, enclosingTypeSubstitution);
    currentFunction = enclosingFunction;
    typeSubstitution = enclosingTypeSubstitution;
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
      Map<TypeParameter, DartType> substitution,
      Map<TypeParameter, DartType> enclosingTypeSubstitution) {
    Field contextField = new Field(
        // TODO(ahe): Rename to #context.
        new Name("context"), type: contextClass.rawType,
        fileUri: currentFileUri);
    Class closureClass = createClosureClass(function, fields: [contextField],
        substitution: substitution);
    closureClass.addMember(
        new Procedure(new Name("call"), ProcedureKind.Method, function,
            fileUri: currentFileUri));
    newLibraryMembers.add(closureClass);
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
        new Arguments(
            <Expression>[accessContext],
            types: new List<DartType>.from(
                substitution.keys.map(
                    (TypeParameter t) {
                      return substitute(
                          new TypeParameterType(t), enclosingTypeSubstitution);
                    }))));
  }

  TreeNode visitField(Field node) {
    currentMember = node;
    context = new NoContext(this);
    if (node.isInstanceMember) {
      Name tearOffName = tearOffGetterNames[node.name];
      if (tearOffName != null) {
        // TODO(ahe): If we rewrite setters, we can rename the field to avoid
        // an indirection in most cases.
        addFieldForwarder(tearOffName, node);
      }
    }
    node = super.visitField(node);
    context = null;
    currentMember = null;
    return node;
  }

  TreeNode visitProcedure(Procedure node) {
    currentMember = node;
    assert(_currentBlock == null);
    assert(_insertionIndex == 0);
    assert(context == null);

    Statement body = node.function.body;

    if (node.isInstanceMember) {
      Name tearOffName = tearOffGetterNames[node.name];
      if (tearOffName != null) {
        if (node.isGetter) {
          // We rename the getter to avoid an indirection in most cases.
          Name oldName = node.name;
          node.name = tearOffName;
          addGetterForwarder(oldName, node);
        } else if (node.kind == ProcedureKind.Method) {
          addTearOffGetter(tearOffName, node);
        }
      }
    }

    if (body == null) return node;

    currentMemberFunction = node.function;

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

    VariableDeclaration self = thisAccess[currentMemberFunction];
    if (self != null) {
      context.extend(self, new ThisExpression());
    }

    node.transformChildren(this);

    _currentBlock = null;
    _insertionIndex = 0;
    context = null;
    currentMemberFunction = null;
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
        ? context.assign(node.variable, node.value,
            voidContext: isInVoidContext(node))
        : node;
  }

  bool isInVoidContext(Expression node) {
    TreeNode parent = node.parent;
    return parent is ExpressionStatement ||
        parent is ForStatement && parent.condition != node;
  }

  DartType visitDartType(DartType node) {
    return substitute(node, typeSubstitution);
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
      return saveContext(() {
        context = context.toNestedContext();
        List<Statement> statements = <Statement>[];
        statements.addAll(node.variables);
        statements.add(node);
        node.variables.clear();
        node.updates.insert(0, cloneContext());
        _currentBlock = new Block(statements);
        _insertionIndex = 0;
        return _currentBlock.accept(this);
      });
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
        ? node : context.lookup(thisAccess[currentMemberFunction]);
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

  TreeNode visitPropertyGet(PropertyGet node) {
    Name tearOffName = tearOffGetterNames[node.name];
    if (tearOffName != null) {
      node.name = tearOffName;
    }
    return super.visitPropertyGet(node);
  }

  TreeNode visitCatch(Catch node) {
    VariableDeclaration exception = node.exception;
    VariableDeclaration stackTrace = node.stackTrace;
    if (stackTrace != null && capturedVariables.contains(stackTrace)) {
      Block block = node.body = ensureBlock(node.body);
      block.parent = node;
      node.stackTrace = new VariableDeclaration(null);
      node.stackTrace.parent = node;
      stackTrace.initializer = new VariableGet(node.stackTrace);
      block.statements.insert(0, stackTrace);
      stackTrace.parent = block;
    }
    if (exception != null && capturedVariables.contains(exception)) {
      Block block = node.body = ensureBlock(node.body);
      block.parent = node;
      node.exception = new VariableDeclaration(null);
      node.exception.parent = node;
      exception.initializer = new VariableGet(node.exception);
      block.statements.insert(0, exception);
      exception.parent = block;
    }
    return super.visitCatch(node);
  }

  Block ensureBlock(Statement statement) {
    return statement is Block ? statement : new Block(<Statement>[statement]);
  }

  /// Creates a closure that will invoke [procedure] and return an expression
  /// that instantiates that closure.
  Expression getTearOffExpression(Procedure procedure) {
    Map<TypeParameter, DartType> substitution = procedure.isInstanceMember
        // Note: we do not attempt to avoid copying type variables that aren't
        // used in the signature of [procedure]. It might be more economical to
        // only copy type variables that are used. However, we assume that
        // passing type arguments that match the enclosing class' type
        // variables will be handled most efficiently.
        ? copyTypeVariables(procedure.enclosingClass.typeParameters)
        : const <TypeParameter, DartType>{};
    Expression receiver = null;
    List<Field> fields = null;
    if (procedure.isInstanceMember) {
      // TODO(ahe): Rename to #self.
      Field self = new Field(new Name("self"), fileUri: currentFileUri);
      self.type = substitute(procedure.enclosingClass.thisType, substitution);
      fields = <Field>[self];
      receiver = new PropertyGet(new ThisExpression(), self.name, self);
    }
    Class closureClass = createClosureClass(procedure.function, fields: fields,
        substitution: substitution);
    closureClass.addMember(
        new Procedure(new Name("call"), ProcedureKind.Method,
            forwardFunction(procedure, receiver, substitution),
            fileUri: currentFileUri));
    newLibraryMembers.add(closureClass);
    Arguments constructorArguments = procedure.isInstanceMember
        ? new Arguments(<Expression>[new ThisExpression()])
        : new Arguments.empty();
    if (substitution.isNotEmpty) {
      constructorArguments.types.addAll(
          procedure.enclosingClass.thisType.typeArguments);
    }
    return new ConstructorInvocation(
        closureClass.constructors.single, constructorArguments);
  }

  /// Creates a function that has the same signature as `procedure.function`
  /// and which forwards all arguments to `procedure`.
  FunctionNode forwardFunction(Procedure procedure, Expression receiver,
      Map<TypeParameter, DartType> substitution) {
    CloneVisitor cloner = substitution.isEmpty
        ? this.cloner
        : new CloneWithoutBody(typeSubstitution: substitution);
    FunctionNode function = procedure.function;
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
    InvocationExpression invocation = procedure.isInstanceMember
        ? new MethodInvocation(receiver, procedure.name, arguments, procedure)
        : new StaticInvocation(procedure, arguments);
    return new FunctionNode(
        new ReturnStatement(invocation),
        typeParameters: typeParameters,
        positionalParameters: positionalParameters,
        namedParameters: namedParameters,
        requiredParameterCount: function.requiredParameterCount,
        returnType: substitute(function.returnType, substitution),
        inferredReturnValue: inferredReturnValue);
  }

  /// Creates copies of the type variables in [original] and returns a
  /// substitution that can be passed to [substitute] to substitute all uses of
  /// [original] with their copies.
  Map<TypeParameter, DartType> copyTypeVariables(
      Iterable<TypeParameter> original) {
    if (original.isEmpty) return const <TypeParameter, DartType>{};
    Map<TypeParameter, DartType> substitution = <TypeParameter, DartType>{};
    for (TypeParameter t in original) {
      substitution[t] = new TypeParameterType(new TypeParameter(t.name));
    }
    substitution.forEach((TypeParameter t, TypeParameterType copy) {
      copy.parameter.bound = substitute(t.bound, substitution);
    });
    return substitution;
  }

  Class createClosureClass(FunctionNode function,
      {List<Field> fields, Map<TypeParameter, DartType> substitution}) {
    List<TypeParameter> typeParameters = new List<TypeParameter>.from(
        substitution.values.map((TypeParameterType t) => t.parameter));
    Class closureClass = new Class(
        name: 'Closure#${localNames[function]}',
        supertype: coreTypes.objectClass.rawType,
        typeParameters: typeParameters,
        implementedTypes: <InterfaceType>[coreTypes.functionClass.rawType],
        fileUri: currentFileUri);
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

  Statement forwardToThisProperty(Member node) {
    assert(node is Field || (node is Procedure && node.isGetter));
    return new ReturnStatement(
        new PropertyGet(new ThisExpression(), node.name, node));
  }

  void addFieldForwarder(Name name, Field field) {
    newClassMembers.add(
        new Procedure(name, ProcedureKind.Getter,
            new FunctionNode(forwardToThisProperty(field)),
            fileUri: currentFileUri));
  }

  Procedure copyWithBody(Procedure procedure, Statement body) {
    Procedure copy = cloner.clone(procedure);
    copy.function.body = body;
    copy.function.body.parent = copy.function;
    return copy;
  }

  void addGetterForwarder(Name name, Procedure getter) {
    assert(getter.isGetter);
    newClassMembers.add(
        copyWithBody(getter, forwardToThisProperty(getter))..name = name);
  }

  void addTearOffGetter(Name name, Procedure procedure) {
    newClassMembers.add(
        new Procedure(name, ProcedureKind.Getter,
            new FunctionNode(
                new ReturnStatement(getTearOffExpression(procedure))),
            fileUri: currentFileUri));
  }

  // TODO(ahe): Remove this method when we don't generate closure classes
  // anymore.
  void addClosureClassNote(Class closureClass) {
    closureClass.addMember(
        new Field(new Name("note"), type: coreTypes.stringClass.rawType,
            initializer: new StringLiteral(
                "This is temporary. The VM doesn't need closure classes."),
            fileUri: currentFileUri));
  }
}
