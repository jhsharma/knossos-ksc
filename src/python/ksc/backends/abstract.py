from functools import wraps

import ksc
from ksc.abstract_value import AbstractValue, ExecutionContext, current_execution_context
from ksc.type import Type

from ksc.backends import common
from ksc.backends.common import (
    add,
    sub,
    mul,
    div_ii,
    div_ff,
    eq,
    lt,
    gt,
    lte,
    gte,
    or_,
    and_,
    abs_,
    max_,
    neg,
    pow,
    to_float_i
)

_built_ins = common._built_ins

def check_args_and_get_context(name, args):
    context = None
    if all(not isinstance(arg, AbstractValue) for arg in args):
        # All arguments are concrete. This can happen due to the
        # compilation of the cost function (e.g., mul@ii)
        return "concrete"
    for i, arg in enumerate(args):
        if not isinstance(arg, AbstractValue) or arg.context is None:
            continue
        ctx = arg.context
        if (context is None or context == "concrete") and ctx is not None:
            context = ctx
        assert (ctx is None
                 or ctx == "concrete"
                 or ctx == context), (f"In the call {name}, expected"
                                      f" {context} for arg#{i+1},"
                                      f" but got {ctx}")
    return context

def _get_data(value):
    if isinstance(value, AbstractValue):
        return value.data
    return value

def _get_edef(defs, name, type, py_name_for_concrete):
    shape_def = defs[f"shape${name}"]
    cost_def = defs[f"cost${name}"]
    @wraps(shape_def)
    def f(*args):
        context = check_args_and_get_context(name, args)
        # assert context is not None, f"In the call to {name}, got no context"
        if context == "concrete":
            d = ksc.backends.abstract.__dict__
            f = d[py_name_for_concrete]
            return AbstractValue.from_data(f(*[_get_data(arg) for arg in args]), context)
        else:
            shape_cost_args = [AbstractValue.in_context(arg, "concrete") for arg in args]
            shape = _get_data(shape_def(*shape_cost_args))
            # handle scalar
            if shape == 0:
                shape = ()
            cost = _get_data(cost_def(*shape_cost_args))
            exec_ctx = current_execution_context()
            exec_ctx.accumulate_cost(name, context, cost)
            return AbstractValue(shape, type, context=context)
    f.__name__ = name
    f.__qualname__ = f"{name} [edef]"
    return f

def index(i, v):
    shape, type = v.shape_type
    assert type.kind == "Vec", f"Called index on non-vector {v}"
    exec_ctx = current_execution_context()
    exec_ctx.accumulate_cost(
        "index",
        v.context,
        exec_ctx.config["index_cost"]
    )
    return AbstractValue(shape[1:], type.children[0], context=v.context)

def size(v):
    shape, type = v.shape_type
    assert type.kind == "Vec", f"Called size on non-vector {v}"
    exec_ctx = current_execution_context()
    exec_ctx.accumulate_cost("size", v.context, exec_ctx.config["size_cost"])
    return AbstractValue.from_data(shape[0], v.context)

def _compute_build_inner_cost(n, f):
    n = _get_data(n)
    if n is None:
        n = exec_ctx.config["assumed_vector_size"]
    # evaluate f in a new context
    with ExecutionContext() as ctx:
        i = AbstractValue((), Type.Integer)
        el = f(i)
    return n, el, ctx.costs[None]

def build(n, f):
    context = check_args_and_get_context("build", [n])
    n, el, inner_cost = _compute_build_inner_cost(n, f)
    exec_ctx = current_execution_context()
    exec_ctx.accumulate_cost(
        "build",
        context,
        exec_ctx.config["build_malloc_cost"] + n * inner_cost
    )
    el_shape, el_type = el.shape_type
    return AbstractValue((n,) + el_shape, Type.Vec(el_type), context=context)

def sumbuild(n, f):
    context = check_args_and_get_context("sumbuild", [n])
    n, el, inner_cost = _compute_build_inner_cost(n, f)
    el_shape, el_type = el.shape_type
    exec_ctx = current_execution_context()
    exec_ctx.accumulate_cost(
        "sumbuild",
        context,
        n * inner_cost + (n - 1) * el_type.num_elements(assumed_vector_size=exec_ctx.config["assumed_vector_size"])
    )
    return AbstractValue(el_shape, el_type, context=context)

def fold(f, s0, xs):
    raise NotImplementedError

def make_tuple(*args):
    context = check_args_and_get_context("tuple", args)
    child_shapes = tuple(arg.shape_type.shape for arg in args)
    child_types = tuple(arg.shape_type.type for arg in args)
    child_data = tuple(_get_data(arg) for arg in args)
    exec_ctx = current_execution_context()
    exec_ctx.accumulate_cost("tuple", context, exec_ctx.config["let_cost"] * len(args))
    return AbstractValue(child_shapes, Type.Tuple(*child_types), child_data, context)

def get_tuple_element(i, tup):
    el_shape = tup.shape_type.shape[i]
    el_type = tup.shape_type.type.children[i]
    tup_data = _get_data(tup)
    el_data = tup_data[i] if isinstance(tup_data, tuple) else None
    exec_ctx = current_execution_context()
    exec_ctx.accumulate_cost("select", tup.context, exec_ctx.config["select_cost"])
    return AbstractValue(el_shape, el_type, el_data, tup.context)

def let(var, body):
    context = check_args_and_get_context("let", [var])
    exec_ctx = current_execution_context()
    exec_ctx.accumulate_cost("let", context, exec_ctx.config["let_cost"])
    return body(var)
