import oneflow as flow
import numpy as np
import tensorflow as tf
from collections import OrderedDict
from test_util import GenArgList


def _random_inputs(params_shape, indices_shape):
    params = np.random.rand(*params_shape).astype(np.float32)
    indices = []
    indices_rows = np.prod(indices_shape[:-1])
    indices_cols = indices_shape[-1]
    for col in range(indices_cols):
        indices_col = np.random.randint(
            low=0, high=params_shape[col], size=(indices_rows,), dtype=np.int32
        ).reshape(indices_shape[:-1])
        indices.append(indices_col)
    indices = np.stack(indices, axis=len(indices_shape) - 1)
    return params, indices


def _make_gather_nd_fn(params, indices, device_type, mirrored, compare_fn):
    flow.clear_default_session()
    func_config = flow.FunctionConfig()
    func_config.default_data_type(flow.float)
    if mirrored:
        func_config.default_distribute_strategy(flow.distribute.mirrored_strategy())
    else:
        func_config.default_distribute_strategy(flow.distribute.consistent_strategy())
    func_config.train.primary_lr(1e-3)
    func_config.train.model_update_conf(dict(naive_conf={}))

    def do_gather_nd(x_blob, i_blob):
        with flow.device_prior_placement(device_type, "0:0"):
            x = flow.get_variable(
                "params",
                shape=params.shape,
                dtype=flow.float32,
                initializer=flow.constant_initializer(0),
            )
            x = x + x_blob
            y = flow.gather_nd(x, i_blob)
            flow.losses.add_loss(y)
        flow.watch_diff(x, compare_fn)
        return y

    if mirrored:

        @flow.function(func_config)
        def gather_nd_fn(
            params_def=flow.MirroredTensorDef(params.shape, dtype=flow.float),
            indices_def=flow.MirroredTensorDef(indices.shape, dtype=flow.int32),
        ):
            return do_gather_nd(params_def, indices_def)

    else:

        @flow.function(func_config)
        def gather_nd_fn(
            params_def=flow.FixedTensorDef(params.shape, dtype=flow.float),
            indices_def=flow.FixedTensorDef(indices.shape, dtype=flow.int32),
        ):
            return do_gather_nd(params_def, indices_def)

    return gather_nd_fn


def _of_dynamic_params_gather_nd(params, indices, static_params_shape, compare_fn):
    flow.clear_default_session()
    func_config = flow.FunctionConfig()
    func_config.default_data_type(flow.float)
    func_config.default_distribute_strategy(flow.distribute.mirrored_strategy())
    func_config.train.primary_lr(1e-3)
    func_config.train.model_update_conf(dict(naive_conf={}))

    @flow.function(func_config)
    def gather_nd_fn(
        params_def=flow.MirroredTensorDef(static_params_shape, dtype=flow.float),
        indices_def=flow.MirroredTensorDef(indices.shape, dtype=flow.int32),
    ):
        with flow.device_prior_placement("gpu", "0:0"):
            one_var = flow.get_variable(
                "one", shape=(1,), dtype=flow.float32, initializer=flow.constant_initializer(1)
            )
            params_var = params_def * one_var
            y = flow.gather_nd(params_var, indices_def)
            flow.losses.add_loss(y)

        flow.watch_diff(params_var, compare_fn)
        return y

    check_point = flow.train.CheckPoint()
    check_point.init()
    return gather_nd_fn([params], [indices]).get().ndarray_list()[0]


def _compare_gather_nd_with_tf(test_case, device_type, params_shape, indices_shape, mirrored=False):
    params, indices = _random_inputs(params_shape, indices_shape)

    i = tf.constant(indices)
    with tf.GradientTape() as t:
        x = tf.Variable(params)
        y = tf.gather_nd(x, i)

    dy = t.gradient(y, x)
    if isinstance(dy, tf.IndexedSlices):
        test_case.assertTrue(np.array_equal(indices.ravel(), dy.indices.numpy().ravel()))
        zero_params = tf.Variable(np.full(params.shape, 0.0, dtype=np.float32))
        dy = tf.tensor_scatter_nd_add(zero_params, i, dy.values)

    if mirrored:

        def compare_dy(params_grad):
            test_case.assertTrue(np.array_equal(dy.numpy(), params_grad.ndarray_list()[0]))

    else:

        def compare_dy(params_grad):
            test_case.assertTrue(np.array_equal(dy.numpy(), params_grad.ndarray()))

    gather_nd_fn = _make_gather_nd_fn(params, indices, device_type, mirrored, compare_dy)

    check_point = flow.train.CheckPoint()
    check_point.init()

    if mirrored:
        of_y = gather_nd_fn([params], [indices]).get().ndarray_list()[0]
    else:
        of_y = gather_nd_fn(params, indices).get().ndarray()

    test_case.assertTrue(np.array_equal(y.numpy(), of_y))


def _compare_dynamic_gather_nd_with_tf(test_case, params_shape, static_params_shape, indices_shape):
    params, indices = _random_inputs(params_shape, indices_shape)

    i = tf.constant(indices)
    with tf.GradientTape() as t:
        x = tf.Variable(params)
        y = tf.gather_nd(x, i)

    dy = t.gradient(y, x)
    if isinstance(dy, tf.IndexedSlices):
        test_case.assertTrue(np.array_equal(indices.ravel(), dy.indices.numpy().ravel()))
        zero_params = tf.constant(np.full(params.shape, 0.0, dtype=np.float32))
        dy = tf.tensor_scatter_nd_add(zero_params, i, dy.values)

    def compare_dy(params_grad):
        test_case.assertTrue(np.array_equal(dy.numpy(), params_grad.ndarray_list()[0]))

    of_y = _of_dynamic_params_gather_nd(params, indices, static_params_shape, compare_dy)
    test_case.assertTrue(np.array_equal(y.numpy(), of_y))


def _of_gather_nd_dynamic_indices(params, indices, indices_static_shape, device_type):
    flow.clear_default_session()
    func_config = flow.FunctionConfig()
    func_config.default_data_type(flow.float)
    func_config.default_distribute_strategy(flow.distribute.mirrored_strategy())

    @flow.function(func_config)
    def gather_nd_fn(
        params_def=flow.MirroredTensorDef(params.shape, dtype=flow.float),
        indices_def=flow.MirroredTensorDef(indices_static_shape, dtype=flow.int32),
    ):
        with flow.device_prior_placement(device_type, "0:0"):
            return flow.gather_nd(params_def, indices_def)

    return gather_nd_fn([params], [indices]).get().ndarray_list()[0]


def _compare_gather_nd_dynamic_indices_with_tf(
    test_case, params_shape, indices_shape, indices_static_shape, device_type
):
    params, indices = _random_inputs(params_shape, indices_shape)

    i = tf.constant(indices)
    x = tf.Variable(params)
    y = tf.gather_nd(x, i)

    of_y = _of_gather_nd_dynamic_indices(params, indices, indices_static_shape, device_type)
    test_case.assertTrue(np.array_equal(y.numpy(), of_y))


def test_gather_nd(test_case):
    arg_dict = OrderedDict()
    arg_dict["device_type"] = ["gpu", "cpu"]
    arg_dict["params_shape"] = [(10,)]
    arg_dict["indices_shape"] = [(5, 1)]
    for arg in GenArgList(arg_dict):
        _compare_gather_nd_with_tf(test_case, *arg)


def test_gather_nd_case_1(test_case):
    arg_dict = OrderedDict()
    arg_dict["device_type"] = ["gpu"]
    arg_dict["params_shape"] = [(20, 10, 10, 3, 3)]
    arg_dict["indices_shape"] = [(2, 3, 3)]
    for arg in GenArgList(arg_dict):
        _compare_gather_nd_with_tf(test_case, *arg)


def test_gather_nd_case_2(test_case):
    arg_dict = OrderedDict()
    arg_dict["device_type"] = ["cpu", "gpu"]
    arg_dict["params_shape"] = [(10, 8, 4)]
    arg_dict["indices_shape"] = [(2, 2)]
    arg_dict["mirrored"] = [True]
    for arg in GenArgList(arg_dict):
        _compare_gather_nd_with_tf(test_case, *arg)


def test_gather_nd_case_3(test_case):
    arg_dict = OrderedDict()
    arg_dict["device_type"] = ["gpu"]
    arg_dict["params_shape"] = [(32, 60, 80, 25)]
    arg_dict["indices_shape"] = [(128, 2)]
    for arg in GenArgList(arg_dict):
        _compare_gather_nd_with_tf(test_case, *arg)


def test_gather_nd_case_4(test_case):
    arg_dict = OrderedDict()
    arg_dict["device_type"] = ["gpu"]
    arg_dict["params_shape"] = [(128, 64, 2, 16, 7)]
    arg_dict["indices_shape"] = [(30, 10, 3)]
    arg_dict["mirrored"] = [True]
    for arg in GenArgList(arg_dict):
        _compare_gather_nd_with_tf(test_case, *arg)


def test_dynamic_gather_nd(test_case):
    arg_dict = OrderedDict()
    arg_dict["params_shape"] = [(30, 15)]
    arg_dict["static_params_shape"] = [(32, 16)]
    arg_dict["indices_shape"] = [(12, 1)]
    for arg in GenArgList(arg_dict):
        _compare_dynamic_gather_nd_with_tf(test_case, *arg)


def test_gather_nd_dynamic_indices(test_case):
    arg_dict = OrderedDict()
    arg_dict["params_shape"] = [(25, 10)]
    arg_dict["indices_shape"] = [(11, 1)]
    arg_dict["indices_static_shape"] = [(15, 1)]
    arg_dict["device_type"] = ["gpu"]
    for arg in GenArgList(arg_dict):
        _compare_gather_nd_dynamic_indices_with_tf(test_case, *arg)


def test_gather_nd_empty_indices(test_case):
    arg_dict = OrderedDict()
    arg_dict["params_shape"] = [(12, 13, 7)]
    arg_dict["indices_shape"] = [(5, 0, 2)]
    arg_dict["indices_static_shape"] = [(5, 10, 2)]
    arg_dict["device_type"] = ["gpu"]
    for arg in GenArgList(arg_dict):
        _compare_gather_nd_dynamic_indices_with_tf(test_case, *arg)