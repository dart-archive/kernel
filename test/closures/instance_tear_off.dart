// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

class C {
  var f = () => "f";
  get g => (x) => "g($x)";
  a() => "a";
  b(x) => x;
  c(x, [y = 2]) => x + y;
  d(x, {y: 2}) => x + y;
}

expect(expected, actual) {
  print("Expecting '$expected' and got '$actual'");
  if (expected != actual) {
    print("Expected '$expected' but got '$actual'");
    throw "Expected '$expected' but got '$actual'";
  }
}

main(arguments) {
  var c = new C();
  expect("f", c.f());
  expect("f", (c.f)());
  expect("g(42)", c.g(42));
  expect("g(42)", (c.g)(42));
  expect("a", c.a());
  expect("a", (c.a)());
  expect(42, c.b(42));
  expect(42, (c.b)(42));
  expect(42, c.c(40));
  expect(42, (c.c)(40));
  expect(87, c.c(80, 7));
  expect(87, (c.c)(80, 7));
  expect(42, c.d(40));
  expect(42, (c.d)(40));
  expect(87, c.d(80, y: 7));
  expect(87, (c.d)(80, y: 7));
}
