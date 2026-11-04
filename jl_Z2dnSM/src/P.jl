module P
const K = 3
helper(x) = x + K
"Fit one replicate."
fit(config) = (helper(config.seed), time_ns())
twin(config) = (0, time_ns())
other(x) = x
greet(config) = config.text
struct Solver{N}
    seed::Int
end
solve(config::Solver{N}) where {N} = N + config.seed
struct Calc{N} end
(::Calc{N})(config) where {N} = N
loader() = 1
const LOADED = loader()
fromload(config) = LOADED
module A
f() = 1
g() = 1
end
module B
f() = 2
g() = 2
end
using .A: f
imported(config) = f()
qualified(config) = A.g()
struct S end
same(config) = S() == S()
shape(config) = size([1 2])

end
