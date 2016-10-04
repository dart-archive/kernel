// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

class C<T> {
  foo() => (T x) {
    T y = x;
    Object z = y;
    C<T> self = this;
    return z as T;
  };
}

main(arguments) {
  print(new C<String>().foo()(arguments.first));
}
