import pytest

import zignal


def test_optimization_policy_enum():
    assert hasattr(zignal, "OptimizationPolicy")
    assert hasattr(zignal.OptimizationPolicy, "MIN")
    assert hasattr(zignal.OptimizationPolicy, "MAX")
    assert zignal.OptimizationPolicy.MIN.value == 0
    assert zignal.OptimizationPolicy.MAX.value == 1


def test_assignment_type():
    assert hasattr(zignal, "Assignment")


def test_solve_assignment_problem_basic():
    # Create a simple 3x3 cost matrix
    costs = zignal.Matrix([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0], [7.0, 8.0, 9.0]])

    # Solve for minimum cost
    result = zignal.solve_assignment_problem(costs)

    # Check result type
    assert isinstance(result, zignal.Assignment)
    assert hasattr(result, "assignments")
    assert hasattr(result, "total_cost")

    # Check assignments
    assert len(result.assignments) == 3
    assert all(x is None or isinstance(x, int) for x in result.assignments)
    assert all(x is None or 0 <= x < 3 for x in result.assignments)

    # Check that total cost is reasonable
    assert isinstance(result.total_cost, float)
    assert result.total_cost >= 0


def test_solve_assignment_problem_minimize():
    # Create a cost matrix where diagonal is cheapest
    costs = zignal.Matrix([[1.0, 10.0, 10.0], [10.0, 2.0, 10.0], [10.0, 10.0, 3.0]])

    # Solve for minimum cost
    result = zignal.solve_assignment_problem(costs, zignal.OptimizationPolicy.MIN)

    # Optimal should be diagonal (0->0, 1->1, 2->2) with cost 1+2+3=6
    assert result.total_cost == pytest.approx(6.0)
    assert result.assignments == [0, 1, 2]


def test_solve_assignment_problem_maximize():
    # Create a profit matrix where anti-diagonal is most profitable
    profits = zignal.Matrix([[1.0, 2.0, 10.0], [2.0, 5.0, 8.0], [10.0, 6.0, 3.0]])

    # Solve for maximum profit
    result = zignal.solve_assignment_problem(profits, zignal.OptimizationPolicy.MAX)

    # Check that we get a valid assignment
    assert len(result.assignments) == 3
    assert result.total_cost > 0  # Should be positive for profits

    # The maximum should be at least 10+8+6=24 (one possible optimal)
    assert result.total_cost >= 24.0


def test_solve_assignment_problem_rectangular():
    # Test 2x3 matrix (more columns than rows)
    costs = zignal.Matrix([[1.0, 2.0, 3.0], [4.0, 2.0, 1.0]])
    result = zignal.solve_assignment_problem(costs)

    # Should have 2 assignments (one for each row)
    assert len(result.assignments) == 2
    assert all(x is None or 0 <= x < 3 for x in result.assignments)

    # Check that assigned columns are unique (if both are assigned)
    assigned_cols = [x for x in result.assignments if x is not None]
    assert len(assigned_cols) == len(set(assigned_cols))  # No duplicates


def test_solve_assignment_problem_rectangular_tall():
    # Test 3x2 matrix
    costs = zignal.Matrix([[1.0, 2.0], [3.0, 1.0], [2.0, 3.0]])
    result = zignal.solve_assignment_problem(costs)

    # Should have 3 potential assignments (one for each row)
    assert len(result.assignments) == 3

    # At most 2 rows can be assigned (only 2 columns available)
    assigned_count = sum(1 for x in result.assignments if x is not None)
    assert assigned_count <= 2


def test_solve_assignment_problem_single_element():
    costs = zignal.Matrix([[5.0]])
    result = zignal.solve_assignment_problem(costs)

    assert len(result.assignments) == 1
    assert result.assignments[0] == 0
    assert result.total_cost == pytest.approx(5.0)


def test_solve_assignment_problem_integer_costs():
    # Create matrix with integer values
    costs = zignal.Matrix([[10, 20, 30], [15, 25, 35], [20, 30, 40]])
    result = zignal.solve_assignment_problem(costs)

    # Should get valid assignments
    assert len(result.assignments) == 3
    assert isinstance(result.total_cost, float)
    assert result.total_cost > 0


def test_solve_assignment_problem_zeros():
    costs = zignal.Matrix([[0.0, 1.0, 2.0], [1.0, 0.0, 3.0], [2.0, 3.0, 0.0]])
    result = zignal.solve_assignment_problem(costs)

    # Optimal is all zeros on diagonal, total cost = 0
    assert result.total_cost == pytest.approx(0.0)


def test_assignment_repr():
    costs = zignal.Matrix([[1.0, 2.0], [3.0, 4.0]])
    result = zignal.solve_assignment_problem(costs)

    repr_str = repr(result)
    assert "Assignment" in repr_str
    assert "total_cost" in repr_str


def test_invalid_policy():
    costs = zignal.Matrix([[1.0, 2.0], [3.0, 4.0]])

    # String values should be rejected
    with pytest.raises(TypeError):
        zignal.solve_assignment_problem(costs, "invalid")

    # Raw ints 0 and 1 are allowed (they match enum values)
    result = zignal.solve_assignment_problem(costs, 0)  # MIN
    assert isinstance(result, zignal.Assignment)

    result = zignal.solve_assignment_problem(costs, 1)  # MAX
    assert isinstance(result, zignal.Assignment)

    # Invalid integer values should be rejected
    with pytest.raises(ValueError):
        zignal.solve_assignment_problem(costs, 2)  # Invalid enum value


def test_invalid_matrix_type():
    costs = [[1.0, 2.0], [3.0, 4.0]]

    # List directly should fail (need Matrix wrapper)
    with pytest.raises(TypeError):
        zignal.solve_assignment_problem(costs)


# ---------------------------------------------------------------------------
# Global optimizer (optimize)
# ---------------------------------------------------------------------------


def test_optimize_minimize_quadratic():
    # Bowl with minimum at (1, -2), value 0.
    # (num_random_samples kept low: these easy bowls converge without the default 5000, and a
    #  smaller surrogate search keeps the suite fast — especially in a Debug-built extension.)
    x, y = zignal.optimize(
        lambda v: (v[0] - 1) ** 2 + (v[1] + 2) ** 2,
        bounds=[(-5, 5), (-5, 5)],
        max_evals=150,
        num_random_samples=500,
    )
    assert len(x) == 2
    assert x[0] == pytest.approx(1.0, abs=0.1)
    assert x[1] == pytest.approx(-2.0, abs=0.1)
    assert y == pytest.approx(0.0, abs=0.05)


def test_optimize_returns_plain_tuple():
    result = zignal.optimize(lambda v: v[0] ** 2, bounds=[(-1, 1)], max_evals=40)
    assert isinstance(result, tuple)
    assert len(result) == 2
    x, y = result
    assert isinstance(x, list)
    assert all(isinstance(c, float) for c in x)
    assert isinstance(y, float)


def test_optimize_maximize():
    # Peak of the negated bowl at (0.5, 0.5), value 0.
    x, y = zignal.optimize(
        lambda v: -((v[0] - 0.5) ** 2 + (v[1] - 0.5) ** 2),
        bounds=[(-2, 2), (-2, 2)],
        max_evals=150,
        policy=zignal.OptimizationPolicy.MAX,
        num_random_samples=500,
    )
    assert x[0] == pytest.approx(0.5, abs=0.1)
    assert x[1] == pytest.approx(0.5, abs=0.1)
    assert y == pytest.approx(0.0, abs=0.05)


def test_optimize_integer_variable():
    # Integer minimum at 3.
    x, y = zignal.optimize(
        lambda v: (v[0] - 3) ** 2,
        bounds=[(0, 10)],
        max_evals=120,
        is_integer=[True],
        num_random_samples=500,
    )
    assert x[0] == float(int(x[0]))  # integral
    assert x[0] == pytest.approx(3.0)


def test_optimize_higher_dimensional():
    target = [1.0, -2.0, 3.0, 0.0]
    x, _ = zignal.optimize(
        lambda v: sum((vi - ti) ** 2 for vi, ti in zip(v, target)),
        bounds=[(-5, 5)] * 4,
        max_evals=250,
        num_random_samples=500,
    )
    assert len(x) == 4
    for xi, ti in zip(x, target):
        assert xi == pytest.approx(ti, abs=0.5)


def test_optimize_seed_reproducible():
    def f(v):
        return (v[0] - 1) ** 2 + (v[1] + 2) ** 2

    x1, y1 = zignal.optimize(f, bounds=[(-5, 5), (-5, 5)], max_evals=80, seed=123)
    x2, y2 = zignal.optimize(f, bounds=[(-5, 5), (-5, 5)], max_evals=80, seed=123)
    assert x1 == x2
    assert y1 == y2


def test_optimize_target_early_stop():
    # A generous target that is reached well within the budget.
    x, y = zignal.optimize(
        lambda v: v[0] ** 2 + v[1] ** 2,
        bounds=[(-5, 5), (-5, 5)],
        max_evals=500,
        target=1.0,
    )
    assert y <= 1.0 + 1e-9


def test_optimize_patience_accepted():
    # patience is honored internally; here we just confirm it is accepted and yields a valid result.
    x, y = zignal.optimize(
        lambda v: v[0] ** 2,
        bounds=[(-3, 3)],
        max_evals=500,
        patience=10,
    )
    assert isinstance(x, list) and isinstance(y, float)


def test_optimize_all_options_accepted():
    x, y = zignal.optimize(
        lambda v: v[0] ** 2,
        bounds=[(-2, 2)],
        max_evals=60,
        policy=zignal.OptimizationPolicy.MIN,
        is_integer=None,
        seed=7,
        target=None,
        patience=None,
        pure_random_probability=0.05,
        num_random_samples=1000,
        trust_region_eps=0.0,
        relative_noise_magnitude=0.001,
        solver_eps=1e-4,
    )
    assert y == pytest.approx(0.0, abs=0.05)


def test_optimize_propagates_objective_exception():
    def boom(v):
        raise ValueError("objective failed")

    with pytest.raises(ValueError, match="objective failed"):
        zignal.optimize(boom, bounds=[(0, 1)], max_evals=50)


def test_optimize_objective_must_return_number():
    with pytest.raises(TypeError):
        zignal.optimize(lambda v: "not a number", bounds=[(0, 1)], max_evals=50)


def test_optimize_non_callable_objective():
    with pytest.raises(TypeError):
        zignal.optimize(42, bounds=[(0, 1)], max_evals=10)


def test_optimize_invalid_max_evals():
    with pytest.raises(ValueError):
        zignal.optimize(lambda v: 0.0, bounds=[(0, 1)], max_evals=0)


def test_optimize_empty_bounds():
    with pytest.raises(ValueError):
        zignal.optimize(lambda v: 0.0, bounds=[], max_evals=10)


def test_optimize_inverted_bound():
    with pytest.raises(ValueError):
        zignal.optimize(lambda v: 0.0, bounds=[(1, 1)], max_evals=10)


def test_optimize_is_integer_length_mismatch():
    with pytest.raises(ValueError):
        zignal.optimize(
            lambda v: v[0] ** 2,
            bounds=[(0, 10), (0, 10)],
            max_evals=10,
            is_integer=[True],
        )


def test_optimize_non_integral_bounds_for_integer_var():
    with pytest.raises(ValueError):
        zignal.optimize(
            lambda v: v[0] ** 2,
            bounds=[(0.5, 3.5)],
            max_evals=10,
            is_integer=[True],
        )


def test_optimize_malformed_bounds():
    with pytest.raises((ValueError, TypeError)):
        zignal.optimize(lambda v: 0.0, bounds=[(0, 1, 2)], max_evals=10)
