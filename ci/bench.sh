#!/usr/bin/env bash
# Small CPU benchmark to scale build times between machines.
# Prints BENCH lines: compile (g++ -O2 of a template-heavy TU), zstd, python; single and all-core.
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
N=$(getconf _NPROCESSORS_ONLN)
CXX=${CXX:-g++}
cat > "$D/b.cc" <<'C'
#include <algorithm>
#include <functional>
#include <iostream>
#include <map>
#include <memory>
#include <regex>
#include <sstream>
#include <string>
#include <unordered_map>
#include <variant>
#include <vector>
template <int N> struct F { static long v(long x) { return F<N-1>::v(x * 31 + N) ^ F<N-2>::v(x + N); } };
template <> struct F<0> { static long v(long x) { return x; } };
template <> struct F<1> { static long v(long x) { return x + 1; } };
using V = std::variant<int, double, std::string, std::vector<int>, std::map<std::string, int>>;
int main(int argc, char** argv) {
  std::regex r1("(a+)(b*)c?[d-f]{2,3}"), r2("^\\s*(\\w+)\\s*=\\s*(.*?)\\s*$", std::regex::icase);
  std::map<std::string, std::vector<V>> m;
  std::unordered_map<int, std::shared_ptr<std::function<long(long)>>> fs;
  for (int i = 0; i < argc + 10; i++) {
    std::ostringstream os; os << "k" << i;
    m[os.str()].push_back(V(i)); m[os.str()].push_back(V(std::to_string(i)));
    fs[i] = std::make_shared<std::function<long(long)>>([i](long x) { return F<18>::v(x) + i; });
  }
  std::smatch sm; std::string s = "key = aaabbcdde";
  long acc = std::regex_search(s, sm, r1) + std::regex_match(s, sm, r2);
  for (auto& [k, v] : m) { std::sort(v.begin(), v.end(), [](const V& a, const V& b) { return a.index() < b.index(); }); acc += v.size(); }
  for (auto& [k, f] : fs) acc += (*f)(k);
  std::cout << acc << "\n";
}
C
echo "BENCH cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 || sysctl -n machdep.cpu.brand_string) n=$N cxx=$($CXX --version | head -1) zstd=$(zstd -V | tr -d '*') py=$(python3 -V)"
now(){ python3 -c 'import time; print(time.time())'; }
best(){ # best of 3 wall times for command
  local b=999999
  for i in 1 2 3; do s=$(now); "$@" >/dev/null 2>&1; e=$(now); t=$(python3 -c "print($e-$s)"); b=$(python3 -c "print(min($b,$t))"); done
  printf '%.2f' "$b"
}
c1(){ $CXX -std=c++20 -O2 -c "$D/b.cc" -o "$D/o1.o"; }
cN(){ for i in $(seq 1 $N); do $CXX -std=c++20 -O2 -c "$D/b.cc" -o "$D/o$i.o" & done; wait; }
echo "BENCH compile_1 $(best c1) s"
echo "BENCH compile_x$N $(best cN) s (for $N compiles)"
head -c 60000000 /dev/urandom | od -An -x | head -c 100000000 > "$D/data"
z1(){ zstd -q -9 -T1 -c "$D/data"; }
zN(){ for i in $(seq 1 $N); do zstd -q -9 -T1 -c "$D/data" & done; wait; }
echo "BENCH zstd9_1 $(best z1) s"
echo "BENCH zstd9_x$N $(best zN) s (for $N runs)"
cat > "$D/p.py" <<'P'
def f(n):
    d = {}
    for i in range(n):
        k = str(i % 1000)
        d[k] = d.get(k, 0) + i * 7 % 13
    return sum(sorted(d.values())[:10])
f(3000000)
P
p1(){ python3 "$D/p.py"; }
pN(){ for i in $(seq 1 $N); do python3 "$D/p.py" & done; wait; }
echo "BENCH python_1 $(best p1) s"
echo "BENCH python_x$N $(best pN) s (for $N runs)"
