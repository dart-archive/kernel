// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

class C<T, S> {
  foo(S s) => (T x) {
    T y = x;
    Object z = y;
    C<T, S> self = this;
    return z as T;
  };

  bar() {
    C<T, S> self = this;
  }
}

main(arguments) {
  print(new C<String, String>().foo(null)(arguments.first));
}
