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
