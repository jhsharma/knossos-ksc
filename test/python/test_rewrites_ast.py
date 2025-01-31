import pytest
from typing import Iterable

from ksc.alpha_equiv import ExprHashedWithAlpha, are_alpha_equivalent
from ksc.expr import Call
from ksc.rewrites import AbstractMatcher, RuleSet
from ksc.rewrites_ast import (
    lift_let_rules,
    lift_if_rules,
    lift_let_over_call,
    new_bind,
    raw_new_bind,
    cse_bind,
    inline_let,
)
from ksc.parse_ks import parse_expr_string
from ksc.expr import Expr
from ksc.type import Type
from ksc.type_propagate import type_propagate, type_propagate_decls
from ksc import utils


lift_let_matcher = RuleSet(lift_let_rules)
lift_if_matcher = RuleSet(lift_if_rules)
lift_all_matcher = RuleSet(lift_let_rules + lift_if_rules)


def assert_expr_sets_alpha_equivalent(s1, s2):
    assert set(ExprHashedWithAlpha(e) for e in s1) == set(
        ExprHashedWithAlpha(e) for e in s2
    )


def apply_all_rewrites(matcher: AbstractMatcher, e: Expr) -> Iterable[Expr]:
    return [m.apply_rewrite() for m in matcher.find_all_matches(e)]


def test_lift_if(prelude_symtab):
    e = parse_expr_string("(add (if p 4.0 2.0) 3.0)")
    expected = parse_expr_string("(if p (add 4.0 3.0) (add 2.0 3.0))")
    type_propagate_decls([e, expected], {**prelude_symtab, "p": Type.Bool})
    match = utils.single_elem(list(lift_if_matcher.find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == expected


def test_lift_if_from_let(prelude_symtab):
    e = parse_expr_string("(let (x 4) (if (gt y 0) x 0))")
    expected = parse_expr_string("(if (gt y 0) (let (x 4) x) (let (x 4) 0))")
    type_propagate_decls([e, expected], {**prelude_symtab, "y": Type.Integer})
    match = utils.single_elem(list(lift_if_matcher.find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == expected
    # Now check we can't lift out of the let if the if-condition uses the bound variable
    e = parse_expr_string("(let (x 4) (if (gt x 0) x 0))")
    type_propagate(e, prelude_symtab)
    assert len(list(lift_if_matcher.find_all_matches(e))) == 0


def test_lift_let(prelude_symtab):
    e = parse_expr_string("(add (let (x 4.0) (add x 2.0)) 3.0)")
    expected = parse_expr_string("(let (x 4.0) (add (add x 2.0) 3.0))")
    type_propagate_decls([e, expected], prelude_symtab)
    match = utils.single_elem(list(lift_let_matcher.find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == expected


def test_interchange_lets(prelude_symtab):
    e = parse_expr_string("(let (x 4) (let (y 5) (add x y)))")
    e2 = parse_expr_string("(let (y 5) (let (x 4) (add x y)))")
    type_propagate_decls([e, e2], prelude_symtab)
    match = utils.single_elem(list(lift_let_matcher.find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == e2
    match2 = utils.single_elem(list(lift_let_matcher.find_all_matches(actual)))
    actual2 = match2.apply_rewrite()
    assert actual2 == e
    # But, can't lift if the inner let uses the outer bound variable
    cant_lift = parse_expr_string("(let (x 5) (let (y (add x 1)) (add x y)))")
    type_propagate(cant_lift, prelude_symtab)
    assert len(list(lift_let_matcher.find_all_matches(cant_lift))) == 0


def test_lift_let_shadowing_call(prelude_symtab):
    matcher = RuleSet([lift_let_over_call])
    e = parse_expr_string("(add (let (x (add x 1)) x) x)")
    # The RHS of the let and the add both refer to another (free) x - just check:
    with pytest.raises(Exception):
        type_propagate(e, prelude_symtab)
    # So, we must rename the bound x so as not to capture the free x
    expected = parse_expr_string("(let (x_0 (add x 1)) (add x_0 x))")
    type_propagate_decls([e, expected], {**prelude_symtab, "x": Type.Integer})
    match = utils.single_elem(list(matcher.find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == expected

    # But, no need to rename if the uses of the free "x" are in the let RHS itself
    # (such uses will be lifted and stay outside the binder):
    e = parse_expr_string("(add (let (x (add x 1)) x) 2)")
    expected = parse_expr_string("(let (x (add x 1)) (add x 2))")
    renamed = parse_expr_string("(let (x_0 (add x 1)) (add x_0 2))")
    match = utils.single_elem(list(matcher.find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == expected
    assert actual != renamed


def test_lift_let_shadowing_parsed(prelude_symtab):
    # Similar to previous, but using ParsedRuleMatcher / ParsedLetLifter
    e = parse_expr_string("(if (let (x (add x 1)) (gt x 2)) x 1)")
    # Must rename the bound x so as not to capture the free x
    expected = parse_expr_string("(let (x_0 (add x 1)) (if (gt x_0 2) x 1))")
    type_propagate_decls([e, expected], {**prelude_symtab, "x": Type.Integer})
    match = utils.single_elem(list(lift_let_matcher.find_all_matches(e)))
    actual = match.apply_rewrite()
    assert actual == expected


def test_lifting_rules_dont_evaluate_computations_early(prelude_symtab):
    symtab = {
        **prelude_symtab,
        "p": Type.Bool,
        "q": Type.Bool,
        "x": Type.Float,
        "a": Type.Float,
        "b": Type.Float,
    }
    e = parse_expr_string("(if p (if (gt x 1.0) a b) 0.0)")
    e2 = parse_expr_string("(if p (let (y (add x 1.0)) y) 0.0)")
    type_propagate_decls([e, e2], symtab)
    # We can't lift the call to 'gt' or 'add' as then it would execute if not p
    assert len(list(lift_all_matcher.find_all_matches(e))) == 0
    assert len(list(lift_all_matcher.find_all_matches(e2))) == 0

    # However it's fine if the predicate (evaluated early) is a simple condition
    e3 = parse_expr_string("(if p (if q (add a 1.0) (add b 2.0)) 5.0)")
    expected3 = parse_expr_string(
        "(if q (if p (add a 1.0) 5.0) (if p (add b 2.0) 5.0))"
    )
    type_propagate_decls([e3, expected3], symtab)
    match = utils.single_elem(list(lift_all_matcher.find_all_matches(e3)))
    assert match.apply_rewrite() == expected3

    e4 = parse_expr_string("(if p (let (y x) y) 0.0)")
    expected4 = parse_expr_string("(let (y x) (if p y 0.0))")
    type_propagate_decls([e4, expected4], symtab)
    match = utils.single_elem(list(lift_all_matcher.find_all_matches(e4)))
    assert match.apply_rewrite() == expected4


def test_lifting_exceptions_from_if(prelude_symtab):
    symtab = {
        **prelude_symtab,
        "p": Type.Bool,
        "i": Type.Integer,
        "x": Type.Tensor(1, Type.Float),
    }
    e = parse_expr_string(
        "(if p (let (x (index i x)) (add x 1.0)) (let (y (index i x)) (mul y 2.0)))"
    )
    # "index i x" can be lifted (despite the potential for an exception)
    # because it is guaranteed to execute either way.
    # Note also the rebinding of x - however no renaming is necessary:
    expected = parse_expr_string(
        "(let (x (index i x)) (if p (add x 1.0) (let (y x) (mul y 2.0))))"
    )
    type_propagate_decls([e, expected], symtab)
    match = utils.single_elem(list(lift_let_matcher.find_all_matches(e)))
    assert match.apply_rewrite() == expected

    # Test another form of rebinding. No renaming is really necessary, but it happens.
    e2 = parse_expr_string(
        "(if p (let (y (index i x)) (add y 1.0)) (let (y (index i x)) (mul y 2.0)))"
    )
    expected2 = parse_expr_string(
        "(let (y_0 (index i x)) (if p (add y_0 1.0) (let (y y_0) (mul y 2.0))))"
    )
    type_propagate_decls([e2, expected2], symtab)
    match2 = utils.single_elem(list(lift_let_matcher.find_all_matches(e2)))
    assert match2.apply_rewrite() == expected2

    # This time extra renaming *is* necessary
    e3 = parse_expr_string(
        "(if p (let (x (index i x)) (add x 1.0)) (let (y (index i x)) (add y (index 0 x))))"
    )
    expected3 = parse_expr_string(
        "(let (x_0 (index i x)) (if p (add x_0 1.0) (let (y x_0) (add y (index 0 x)))))"
    )
    type_propagate_decls([e3, expected3], symtab)
    match3 = utils.single_elem(list(lift_let_matcher.find_all_matches(e3)))
    assert match3.apply_rewrite() == expected3


def test_lifting_over_build(prelude_symtab):
    e = parse_expr_string(
        "(build 10 (lam (i : Integer) (let (x (add 5 7)) (if (gt x 5) x i))))"
    )
    expected = parse_expr_string(
        """(if (gt 10 0)
               (let (x (add 5 7)) (build 10 (lam (i : Integer) (if (gt x 5) x i))))
               (build 0 (lam (i : Integer) (let (x (add 5 7)) (if (gt x 5) x i)))))"""
    )
    type_propagate_decls([e, expected], prelude_symtab)
    match = utils.single_elem(list(lift_all_matcher.find_all_matches(e)))
    actual = match.apply_rewrite()
    # Let should have been lifted:
    assert actual == expected

    # Discard the if+else; in the "then" case, now we can lift the if out of the build:
    match2 = utils.single_elem(list(lift_all_matcher.find_all_matches(actual.t_body)))
    actual2 = match2.apply_rewrite()
    expected2 = parse_expr_string(
        """
    (let (x (add 5 7)) (if (gt 10 0)
                           (if (gt x 5) (build 10 (lam (i : Integer) x)) (build 10 (lam (i : Integer) i)))
                           (build 10 (lam (i : Integer) (if (gt x 5) x i)))))
    """
    )
    type_propagate_decls([expected2], prelude_symtab)
    assert actual2 == expected2

    # But, don't allow lifting an expression that refers to the build/lam-bound 'i':
    e3 = parse_expr_string(
        "(build 10 (lam (i : Integer) (let (x (add 5 i)) (if (gt i 5) x i))))"
    )
    type_propagate(e3, prelude_symtab)
    assert len(list(lift_let_matcher.find_all_matches(e3))) == 0
    # Can lift the "if" as it does not use x:
    expected3 = parse_expr_string(
        "(build 10 (lam (i : Integer) (if (gt i 5) (let (x (add 5 i)) x) (let (x (add 5 i)) i))))"
    )
    type_propagate(expected3, prelude_symtab)
    match3 = utils.single_elem(list(lift_if_matcher.find_all_matches(e3)))
    actual3 = match3.apply_rewrite()
    assert actual3 == expected3


def test_new_bind(prelude_symtab):
    symtab = {**prelude_symtab, "x": Type.Integer}
    input = parse_expr_string("(let (y (add x 1)) (add y (add x 1)))")
    expected = parse_expr_string("(let (y (add x 1)) (add y (let (z (add x 1)) z)))")
    expected_raw = [expected] + [
        parse_expr_string("(let (z (let (y (add x 1)) (add y (add x 1)))) z)"),
        parse_expr_string("(let (y (let (z (add x 1)) z)) (add y (add x 1)))"),
        parse_expr_string("(let (y (add x 1)) (let (z (add y (add x 1))) z))"),
    ]
    type_propagate_decls(expected_raw + [input], symtab)
    actual_raw = apply_all_rewrites(RuleSet([raw_new_bind]), input)
    assert_expr_sets_alpha_equivalent(actual_raw, expected_raw)

    match = utils.single_elem(list(RuleSet([new_bind]).find_all_matches(input)))
    actual = match.apply_rewrite()
    assert are_alpha_equivalent(actual, expected)


def test_cse_sequence(prelude_symtab):
    symtab = {**prelude_symtab, "x": Type.Integer}
    new_bind_matcher = RuleSet([new_bind])
    input = parse_expr_string("(mul (add x 1) (add x 1))")
    expected_new_binds = [
        parse_expr_string("(mul (add x 1) (let (y (add x 1)) y))"),
        parse_expr_string("(mul (let (y (add x 1)) y) (add x 1))"),
    ]
    type_propagate_decls(expected_new_binds + [input], symtab)
    actual_new_binds = apply_all_rewrites(new_bind_matcher, input)
    assert_expr_sets_alpha_equivalent(actual_new_binds, expected_new_binds)
    # We'll continue on the one where the first arg of the mul is still an add
    actual_new_bind = utils.single_elem(
        [expr for expr in actual_new_binds if isinstance(expr.args[0], Call)]
    )

    expected_lift1 = parse_expr_string("(let (y (add x 1)) (mul (add x 1) y))")
    type_propagate(expected_lift1, symtab)
    matches = lift_let_matcher.find_all_matches(actual_new_bind)
    actual_lift1 = utils.single_elem(list(matches)).apply_rewrite()
    assert are_alpha_equivalent(actual_lift1, expected_lift1)
    # Result: actual_lift1

    expected_new_bind2 = parse_expr_string(
        "(let (y (add x 1)) (mul (let (z (add x 1)) z) y))"
    )
    type_propagate(expected_new_bind2, symtab)
    matches = new_bind_matcher.find_all_matches(actual_lift1)
    actual_new_bind2 = utils.single_elem(list(matches)).apply_rewrite()
    assert are_alpha_equivalent(actual_new_bind2, expected_new_bind2)
    # Result: actual_new_bind2

    expected_lift2 = parse_expr_string(
        "(let (y (add x 1)) (let (z (add x 1)) (mul z y)))"
    )
    type_propagate(expected_lift2, symtab)
    matches = lift_let_matcher.find_all_matches(actual_new_bind2)
    actual_lift2 = utils.single_elem(list(matches)).apply_rewrite()
    assert are_alpha_equivalent(actual_lift2, expected_lift2)
    # Result: actual_lift2

    expected_cse_bind = parse_expr_string("(let (y (add x 1)) (let (z y) (mul z y)))")
    type_propagate(expected_cse_bind, symtab)
    matches = RuleSet([cse_bind]).find_all_matches(actual_lift2)
    actual_cse_bind = utils.single_elem(list(matches)).apply_rewrite()
    assert are_alpha_equivalent(actual_cse_bind, expected_cse_bind)
    # Result: actual_cse_bind

    # Finally, clean up the extra variable assignment, and test inline_let
    expected_inline_lets = [
        parse_expr_string("(let (y (add x 1)) (mul y y))"),  # Inline z - right
        parse_expr_string("(let (z (add x 1)) (mul z (add x 1)))"),  # Inline y - bad
    ]
    type_propagate_decls(expected_inline_lets, symtab)
    actual_inline_lets = apply_all_rewrites(RuleSet([inline_let]), actual_cse_bind)
    assert_expr_sets_alpha_equivalent(expected_inline_lets, actual_inline_lets)
