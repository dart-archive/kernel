// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library test.kernel.closures.suite;

import 'dart:async' show
    Future;

import 'dart:io' show
    Directory,
    File,
    IOSink;

import 'package:kernel/kernel.dart' show
    loadProgramFromBinary;

import 'package:kernel/text/ast_to_text.dart' show
    Printer;

import 'package:testing/testing.dart' show
    Result,
    StdioProcess,
    Step;

import 'package:kernel/ast.dart' show
    Library,
    Program;

import 'package:kernel/checks.dart' show
    runSanityChecks;

import 'package:kernel/binary/ast_to_binary.dart' show
    BinaryPrinter;

const bool generateExpectations =
    const bool.fromEnvironment("generateExpectations");

Future<bool> fileExists(Uri base, String path) async {
  return await new File.fromUri(base.resolve(path)).exists();
}

class Print extends Step<Program, Program, dynamic> {
  const Print();

  String get name => "print";

  Future<Result<Program>> run(Program program, _) async {
    StringBuffer sb = new StringBuffer();
    Printer printer = new Printer(sb);
    for (Library library in program.libraries) {
      if (library.importUri.scheme != "dart") {
        printer.writeLibraryFile(library);
      }
    }
    print("$sb");
    return pass(program);
  }
}

class SanityCheck extends Step<Program, Program, dynamic> {
  const SanityCheck();

  String get name => "sanity check";

  Future<Result<Program>> run(Program program, _) async {
    try {
      runSanityChecks(program);
      return pass(program);
    } catch (e, s) {
      return crash(e, s);
    }
  }
}

class MatchExpectation extends Step<Program, Program, dynamic> {
  final String suffix;

  const MatchExpectation(this.suffix);

  String get name => "match expectations";

  Future<Result<Program>> run(Program program, _) async {
    Library library = program.libraries.firstWhere(
        (Library library) =>library.importUri.scheme != "dart");
    Uri uri = library.importUri;
    StringBuffer buffer = new StringBuffer();
    new Printer(buffer).writeLibraryFile(library);

    File expectedFile = new File("${uri.toFilePath()}$suffix");
    if (await expectedFile.exists()) {
      String expected = await expectedFile.readAsString();
      if (expected.trim() != "$buffer".trim()) {
        String diff = await runDiff(expectedFile.uri, "$buffer");
        return fail(null, "$uri doesn't match ${expectedFile.uri}\n$diff");
      }
    } else if (generateExpectations) {
      await openWrite(expectedFile.uri, (IOSink sink) {
          sink.writeln("$buffer".trim());
        });
      return fail(program, "Generated ${expectedFile.uri}");
    } else {
      return fail(program, """
Please create file ${expectedFile.path} with this content:
$buffer""");
    }
    return pass(program);
  }
}

class WriteDill extends Step<Program, Uri, dynamic> {
  const WriteDill();

  String get name => "write .dill";

  Future<Result<Uri>> run(Program program, _) async {
    Directory tmp = await Directory.systemTemp.createTemp();
    Uri uri = tmp.uri.resolve("generated.dill");
    File generated = new File.fromUri(uri);
    IOSink sink = generated.openWrite();
    try {
      new BinaryPrinter(sink).writeProgramFile(program);
    } catch (e, s) {
      return fail(uri, e, s);
    } finally {
      print("Wrote `${generated.path}`");
      await sink.close();
    }
    return pass(uri);
  }
}

class ReadDill extends Step<Uri, Uri, dynamic> {
  const ReadDill();

  String get name => "read .dill";

  Future<Result<Uri>> run(Uri uri, _) async {
    try {
      loadProgramFromBinary(uri.toFilePath());
    } catch (e, s) {
      return fail(uri, e, s);
    }
    return pass(uri);
  }
}

Future<String> runDiff(Uri expected, String actual) async {
  StdioProcess process = await StdioProcess.run(
      "diff", <String>["-u", expected.toFilePath(), "-"], input: actual);
  return process.output;
}

Future openWrite(Uri uri, f(IOSink sink)) async {
  IOSink sink = new File.fromUri(uri).openWrite();
  try {
    await f(sink);
  } finally {
    await sink.close();
  }
  print("Wrote $uri");
}
