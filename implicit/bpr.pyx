import cython
from cython cimport floating, integral
import logging
import itertools
import multiprocessing
import random
import time
import tqdm

from cython.parallel import parallel, prange
from libc.math cimport exp
from libc.stdio cimport printf
from libcpp cimport bool
from libcpp.vector cimport vector
from libcpp.algorithm cimport binary_search

import numpy as np
import scipy.sparse

import implicit.cuda

from .recommender_base import MatrixFactorizationBase
from abc import ABCMeta, abstractmethod


cdef extern from "<random>" namespace "std":
    cdef cppclass mt19937:
        mt19937(unsigned int)

    cdef cppclass uniform_int_distribution[T]:
        uniform_int_distribution(T, T)
        T operator()(mt19937) nogil

    cdef cppclass uniform_real_distribution[T]:
        uniform_real_distribution()
        uniform_real_distribution(T a, T b)
        T operator()(mt19937) nogil

log = logging.getLogger("implicit")

# thin wrapper around omp_get_thread_num (since referencing directly will cause OSX
# build to fail)
cdef extern from "bpr.h" namespace "implicit" nogil:
    cdef int get_thread_num()


@cython.boundscheck(False)
cdef bool has_non_zero(integral[:] indptr, integral[:] indices,
                       integral rowid, integral colid) nogil:
    """ Given a CSR matrix, returns whether the [rowid, colid] contains a non zero.
    Assumes the CSR matrix has sorted indices """
    return binary_search(&indices[indptr[rowid]], &indices[indptr[rowid + 1]], colid)


cdef class RNGVector(object):
    """ This class creates one c++ rng object per thread, and enables us to randomly sample
    liked/disliked items here in a thread safe manner """
    cdef vector[mt19937] rng
    cdef vector[uniform_int_distribution[long]]  dist
    cdef vector[uniform_real_distribution[float]]  real

    def __init__(self, int num_threads, long rows):
        for i in range(num_threads):
            self.rng.push_back(mt19937(np.random.randint(2**31)))
            self.dist.push_back(uniform_int_distribution[long](0, rows))
            self.real.push_back(uniform_real_distribution[float](0.0, 1.0))

    cdef inline long generate(self, int thread_id) nogil:
        return self.dist[thread_id](self.rng[thread_id])

    cdef inline float sample(self, int thread_id) nogil:
        return self.real[thread_id](self.rng[thread_id])


class BayesianPersonalizedRanking(MatrixFactorizationBase):
    """ Bayesian Personalized Ranking

    A recommender model that learns  a matrix factorization embedding based off minimizing the
    pairwise ranking loss described in the paper `BPR: Bayesian Personalized Ranking from Implicit
    Feedback <https://arxiv.org/pdf/1205.2618.pdf>`_.

    Parameters
    ----------
    factors : int, optional
        The number of latent factors to compute
    learning_rate : float, optional
        The learning rate to apply for SGD updates during training
    regularization : float, optional
        The regularization factor to use
    dtype : data-type, optional
        Specifies whether to generate 64 bit or 32 bit floating point factors
    use_gpu : bool, optional
        Fit on the GPU if available
    iterations : int, optional
        The number of training epochs to use when fitting the data
    verify_negative_samples: bool, optional
        When sampling negative items, check if the randomly picked negative item has actually
        been liked by the user. This check increases the time needed to train but usually leads
        to better predictions.
    num_threads : int, optional
        The number of threads to use for fitting the model. This only
        applies for the native extensions. Specifying 0 means to default
        to the number of cores on the machine.

    Attributes
    ----------
    item_factors : ndarray
        Array of latent factors for each item in the training set
    user_factors : ndarray
        Array of latent factors for each user in the training set
    """
    def __init__(self, factors=100, learning_rate=0.01, regularization=0.01, dtype=np.float32,
                 iterations=100, use_gpu=implicit.cuda.HAS_CUDA, num_threads=0,
                 verify_negative_samples=True):
        super(BayesianPersonalizedRanking, self).__init__()

        if use_gpu and (factors + 1) % 32:
            padding = 32 - (factors + 1) % 32
            log.warning("GPU training requires factor size to be a multiple of 32 - 1."
                        " Increasing factors from %i to %i.", factors, factors + padding)
            factors += padding

        self.factors = factors
        self.learning_rate = learning_rate
        self.iterations = iterations
        self.regularization = regularization
        self.dtype = dtype
        self.use_gpu = use_gpu
        self.num_threads = num_threads
        self.verify_negative_samples = verify_negative_samples
        self.show_progress = True

    @cython.cdivision(True)
    @cython.boundscheck(False)
    def fit(self, item_users):
        """ Factorizes the item_users matrix

        Parameters
        ----------
        item_users: coo_matrix
            Matrix of confidences for the liked items. This matrix should be a coo_matrix where
            the rows of the matrix are the item, and the columns are the users that liked that item.
            BPR ignores the weight value of the matrix right now - it treats non zero entries
            as a binary signal that the user liked the item.
        """
        # for now, all we handle is float 32 values
        if item_users.dtype != np.float32:
            item_users = item_users.astype(np.float32)

        items, users = item_users.shape

        # We need efficient user lookup for case of removing own likes
        # TODO: might make more sense to just changes inputs to be users by items instead
        # but that would be a major breaking API change
        user_items = item_users.T.tocsr()
        if not user_items.has_sorted_indices:
            user_items.sort_indices()

        # this basically calculates the 'row' attribute of a COO matrix
        # without requiring us to get the whole COO matrix
        user_counts = np.ediff1d(user_items.indptr)
        userids = np.repeat(np.arange(users), user_counts).astype(user_items.indices.dtype)

        # create factors if not already created.
        # Note: the final dimension is for the item bias term - which is set to a 1 for all users
        # this simplifies interfacing with approximate nearest neighbours libraries etc
        if self.item_factors is None:
            self.item_factors = (np.random.rand(items, self.factors + 1).astype(self.dtype) - .5)
            self.item_factors /= self.factors

            # set factors to all zeros for items without any ratings
            item_counts = np.bincount(user_items.indices, minlength=items)
            self.item_factors[item_counts == 0] = np.zeros(self.factors + 1)

        if self.user_factors is None:
            self.user_factors = (np.random.rand(users, self.factors + 1).astype(self.dtype) - .5)
            self.user_factors /= self.factors

            # set factors to all zeros for users without any ratings
            self.user_factors[user_counts == 0] = np.zeros(self.factors + 1)

            self.user_factors[:, self.factors] = 1.0

        if self.use_gpu:
            return self._fit_gpu(user_items, userids)

        # we accept num_threads = 0 as indicating to create as many threads as we have cores,
        # but in that case we need the number of cores, since we need to initialize RNG state per
        # thread. Get the appropiate value back from openmp
        cdef int num_threads = self.num_threads
        if not num_threads:
            num_threads = multiprocessing.cpu_count()

        # initialize RNG's, one per thread.
        cdef RNGVector rng = RNGVector(num_threads, len(user_items.data) - 1)
        log.debug("Running %i BPR training epochs", self.iterations)
        with tqdm.tqdm(total=self.iterations, disable=not self.show_progress) as progress:
            for epoch in range(self.iterations):
                correct, skipped = bpr_update(rng, userids, user_items.indices, user_items.indptr,
                                              self.user_factors, self.item_factors,
                                              self.learning_rate, self.regularization, num_threads,
                                              self.verify_negative_samples)
                progress.update(1)
                total = len(user_items.data)
                progress.set_postfix({"correct": "%.2f%%" % (100.0 * correct / (total - skipped)),
                                      "skipped": "%.2f%%" % (100.0 * skipped / total)})

    def _fit_gpu(self, user_items, userids_host):
        if not implicit.cuda.HAS_CUDA:
            raise ValueError("No CUDA extension has been built, can't train on GPU.")

        if self.dtype == np.float64:
            log.warning("Factors of dtype float64 aren't supported with gpu fitting. "
                        "Converting factors to float32")
            self.user_factors = self.user_factors.astype(np.float32)
            self.item_factors = self.item_factors.astype(np.float32)

        userids = implicit.cuda.CuIntVector(userids_host)
        itemids = implicit.cuda.CuIntVector(user_items.indices)
        indptr = implicit.cuda.CuIntVector(user_items.indptr)

        X = implicit.cuda.CuDenseMatrix(self.user_factors)
        Y = implicit.cuda.CuDenseMatrix(self.item_factors)

        log.debug("Running %i BPR training epochs", self.iterations)
        with tqdm.tqdm(total=self.iterations, disable=not self.show_progress) as progress:
            for epoch in range(self.iterations):
                correct, skipped = implicit.cuda.cu_bpr_update(userids, itemids, indptr,
                                                               X, Y, self.learning_rate,
                                                               self.regularization,
                                                               np.random.randint(2**31),
                                                               self.verify_negative_samples)
                progress.update(1)
                total = len(user_items.data)
                progress.set_postfix({"correct": "%.2f%%" % (100.0 * correct / (total - skipped)),
                                      "skipped": "%.2f%%" % (100.0 * skipped / total)})

        X.to_host(self.user_factors)
        Y.to_host(self.item_factors)


@cython.cdivision(True)
@cython.boundscheck(False)
def bpr_update(RNGVector rng,
               integral[:] userids, integral[:] itemids, integral[:] indptr,
               floating[:, :] X, floating[:, :] Y,
               float learning_rate, float reg, int num_threads,
               bool verify_neg):
    cdef integral users = X.shape[0], items = Y.shape[0]
    cdef long samples = len(userids), i, liked_index, disliked_index, correct = 0, skipped = 0
    cdef integral j, liked_id, disliked_id, thread_id, user_id
    cdef floating z, score, temp

    cdef floating * user
    cdef floating * liked
    cdef floating * disliked

    cdef integral factors = X.shape[1] - 1

    with nogil, parallel(num_threads=num_threads):

        thread_id = get_thread_num()
        for i in prange(samples, schedule='guided'):
            liked_index = rng.generate(thread_id)
            liked_id = itemids[liked_index]
            user_id = userids[liked_index]

            # if the user has liked the item, skip this for now
            disliked_index = rng.generate(thread_id)
            disliked_id = itemids[disliked_index]

            if verify_neg and has_non_zero(indptr, itemids, user_id, disliked_id):
                skipped += 1
                continue

            # get pointers to the relevant factors
            user, liked, disliked = &X[user_id, 0], &Y[liked_id, 0], &Y[disliked_id, 0]

            # compute the score
            score = 0
            for j in range(factors + 1):
                score = score + user[j] * (liked[j] - disliked[j])
            z = 1.0 / (1.0 + exp(score))

            if z < .5:
                correct += 1

            # update the factors via sgd.
            for j in range(factors):
                temp = user[j]
                user[j] += learning_rate * (z * (liked[j] - disliked[j]) - reg * user[j])
                liked[j] += learning_rate * (z * temp - reg * liked[j])
                disliked[j] += learning_rate * (-z * temp - reg * disliked[j])

            # update item bias terms (last column of factorized matrix)
            liked[factors] += learning_rate * (z - reg * liked[factors])
            disliked[factors] += learning_rate * (-z - reg * disliked[factors])

    return correct, skipped


class BayesianPersonalizedFavorRanking(BayesianPersonalizedRanking):
    """ Bayesian Personalized Ranking

    A recommender model that learns  a matrix factorization embedding based off minimizing the
    pairwise ranking loss described in the paper `BPR: Bayesian Personalized Ranking from Implicit
    Feedback <https://arxiv.org/pdf/1205.2618.pdf>`_.
    Update: only compare the favored items

    Parameters
    ----------
    factors : int, optional
        The number of latent factors to compute
    learning_rate : float, optional
        The learning rate to apply for SGD updates during training
    regularization : float, optional
        The regularization factor to use
    dtype : data-type, optional
        Specifies whether to generate 64 bit or 32 bit floating point factors
    use_gpu : bool, optional
        Fit on the GPU if available
    iterations : int, optional
        The number of training epochs to use when fitting the data
    verify_same: bool, optional
        When sampling negative items, check if the randomly picked negative item has actually
        been liked by the user. This check increases the time needed to train but usually leads
        to better predictions.
    num_threads : int, optional
        The number of threads to use for fitting the model. This only
        applies for the native extensions. Specifying 0 means to default
        to the number of cores on the machine.

    Attributes
    ----------
    item_factors : ndarray
        Array of latent factors for each item in the training set
    user_factors : ndarray
        Array of latent factors for each user in the training set
    """
    def __init__(self, factors=100, learning_rate=0.01, regularization=0.01, dtype=np.float32,
                 iterations=100, num_threads=0, verify_same=True):
        super(BayesianPersonalizedFavorRanking, self).__init__()


        self.factors = factors
        self.learning_rate = learning_rate
        self.iterations = iterations
        self.regularization = regularization
        self.dtype = dtype
        self.num_threads = num_threads
        self.verify_same = verify_same
        self.show_progress = True
        self.user_items = None

    @cython.cdivision(True)
    @cython.boundscheck(False)
    def fit(self, item_users):
        """ Factorizes the item_users matrix

        Parameters
        ----------
        item_users: coo_matrix
            Matrix of confidences for the liked items. This matrix should be a coo_matrix where
            the rows of the matrix are the item, and the columns are the users that liked that item.
            BPR ignores the weight value of the matrix right now - it treats non zero entries
            as a binary signal that the user liked the item.
        """
        # for now, all we handle is float 32 values
        if item_users.dtype != np.float32:
            item_users = item_users.astype(np.float32)

        items, users = item_users.shape

        # We need efficient user lookup for case of removing own likes
        # TODO: might make more sense to just changes inputs to be users by items instead
        # but that would be a major breaking API change
        user_items = item_users.T.tocsr()
        self.user_items = user_items
        if not user_items.has_sorted_indices:
            user_items.sort_indices()

        # this basically calculates the 'row' attribute of a COO matrix
        # without requiring us to get the whole COO matrix
        user_counts = np.ediff1d(user_items.indptr)
        userids = np.repeat(np.arange(users), user_counts).astype(user_items.indices.dtype)

        # create factors if not already created.
        # Note: the final dimension is for the item bias term - which is set to a 1 for all users
        # this simplifies interfacing with approximate nearest neighbours libraries etc
        if self.item_factors is None:
            self.item_factors = (np.random.rand(items, self.factors + 1).astype(self.dtype) - .5)
            self.item_factors /= self.factors

            # set factors to all zeros for items without any ratings
            item_counts = np.bincount(user_items.indices, minlength=items)
            self.item_factors[item_counts == 0] = np.zeros(self.factors + 1)

        if self.user_factors is None:
            self.user_factors = (np.random.rand(users, self.factors + 1).astype(self.dtype) - .5)
            self.user_factors /= self.factors

            # set factors to all zeros for users without any ratings
            self.user_factors[user_counts == 0] = np.zeros(self.factors + 1)

            self.user_factors[:, self.factors] = 1.0

        # we accept num_threads = 0 as indicating to create as many threads as we have cores,
        # but in that case we need the number of cores, since we need to initialize RNG state per
        # thread. Get the appropiate value back from openmp
        cdef int num_threads = self.num_threads
        if not num_threads:
            num_threads = multiprocessing.cpu_count()

        # initialize RNG's, one per thread.
        cdef RNGVector rng = RNGVector(num_threads, len(user_items.data) - 1)
        log.debug("Running %i BPR training epochs", self.iterations)
        with tqdm.tqdm(total=self.iterations, disable=not self.show_progress) as progress:
            for epoch in range(self.iterations):
                correct, skipped = bpr_favor_update(rng, userids, user_items.indices, user_items.indptr,
                                                   self.user_factors, self.item_factors,
                                                   self.learning_rate, self.regularization, num_threads,
                                                   self.verify_same, user_items.data)
                progress.update(1)
                total = len(user_items.data)
                progress.set_postfix({"correct": "%.2f%%" % (100.0 * correct / (total - skipped)),
                                      "skipped": "%.2f%%" % (100.0 * skipped / total)})

    @abstractmethod
    def recommend(self, userid, N=10, filter_liked=False, filter_items=None, recalculate_user=False):
        """
        Recommends items for a user

        Calculates the N best recommendations for a user, and returns a list of itemids, score.

        Parameters
        ----------
        userid : int
            The userid to calculate recommendations for
        N : int, optional
            The number of results to return
        filter_items : sequence of ints, optional
            List of extra item ids to filter out from the output
        recalculate_user : bool, optional
            When true, don't rely on stored user state and instead recalculate from the
            passed in user_items

        Returns
        -------
        list
            List of (itemid, score) tuples
        """
        user = self._user_factor(userid, self.user_items, recalculate_user)
        # calculate the top N items, removing the users own liked items from the results
        liked = set(self.user_items[userid].indices)
        scores = self.item_factors.dot(user)
        if filter_items:
            liked.update(filter_items)

        count = N + len(liked)
        if count < len(scores):
            ids = np.argpartition(scores, -count)[-count:]
            best = sorted(zip(ids, scores[ids]), key=lambda x: -x[1])
        else:
            best = sorted(enumerate(scores), key=lambda x: -x[1])
        if filter_liked:
            return list(itertools.islice((rec for rec in best if rec[0] not in liked), N))
        return list(itertools.islice((rec for rec in best), N))

    @abstractmethod
    def rank_items(self, userid, selected_items, recalculate_user=False):
        """
        Rank given items for a user and returns sorted item list.

        Parameters
        ----------
        userid : int
            The userid to calculate recommendations for
        selected_items : List of itemids
        recalculate_user : bool, optional
            When true, don't rely on stored user state and instead recalculate from the
            passed in user_items

        Returns
        -------
        list
            List of (itemid, score) tuples. it only contains items that appears in
            input parameter selected_items
        """
        user = self._user_factor(userid, self.user_items, recalculate_user)

        # check selected items are  in the model
        if max(selected_items) >= self.user_items.shape[1] or min(selected_items) < 0:
            raise IndexError("Some of selected itemids are not in the model")

        item_factors = self.item_factors[selected_items]
        # calculate relevance scores of given items w.r.t the user
        scores = item_factors.dot(user)

        # return sorted results
        return sorted(zip(selected_items, scores), key=lambda x: -x[1])


@cython.cdivision(True)
@cython.boundscheck(False)
def bpr_favor_update(RNGVector rng,
               integral[:] userids, integral[:] itemids, integral[:] indptr,
               floating[:, :] X, floating[:, :] Y,
               float learning_rate, float reg, int num_threads,
               bool verify_neg,
               floating[:] score_vec):
    cdef integral users = X.shape[0], items = Y.shape[0]
    cdef long samples = len(userids), i, liked_index, disliked_index, correct = 0, skipped = 0
    cdef integral j, liked_id, disliked_id, thread_id, user_id
    cdef floating z, score, temp, liked_score, disliked_score, random_index

    cdef floating * user
    cdef floating * liked
    cdef floating * disliked

    cdef integral factors = X.shape[1] - 1

    with nogil, parallel(num_threads=num_threads):

        thread_id = get_thread_num()
        for i in prange(samples, schedule='guided'):
            liked_index = rng.generate(thread_id)
            liked_id = itemids[liked_index]
            user_id = userids[liked_index]

            random_index = rng.sample(thread_id)
            disliked_index = indptr[user_id] + <long>((indptr[user_id + 1] - indptr[user_id]) * random_index )
            disliked_id = itemids[disliked_index]

            # if disliked == liked, skip
            if verify_neg and disliked_index == liked_index:
                skipped += 1
                continue

            liked_score = score_vec[liked_index]
            disliked_score = score_vec[disliked_index]
            if liked_score < disliked_score:
                liked_id, disliked_id = disliked_id, liked_id


            # get pointers to the relevant factors
            user, liked, disliked = &X[user_id, 0], &Y[liked_id, 0], &Y[disliked_id, 0]


            # compute the score
            score = 0
            for j in range(factors + 1):
                score = score + user[j] * (liked[j] - disliked[j])
            z = 1.0 / (1.0 + exp(score))

            if z < .5:
                correct += 1

            # update the factors via sgd.
            for j in range(factors):
                temp = user[j]
                user[j] += learning_rate * (z * (liked[j] - disliked[j]) - reg * user[j])
                liked[j] += learning_rate * (z * temp - reg * liked[j])
                disliked[j] += learning_rate * (-z * temp - reg * disliked[j])

            # update item bias terms (last column of factorized matrix)
            liked[factors] += learning_rate * (z - reg * liked[factors])
            disliked[factors] += learning_rate * (-z - reg * disliked[factors])

    return correct, skipped
