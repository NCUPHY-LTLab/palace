// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

#include <cmath>
#include <string>
#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_floating_point.hpp>
#include "linalg/iterative.hpp"
#include "linalg/jacobi.hpp"
#include "linalg/operator.hpp"
#include "utils/communication.hpp"

namespace palace
{

using namespace Catch::Matchers;

namespace
{

class SpdTestOperator : public Operator
{
public:
  SpdTestOperator() : Operator(2) {}

  // JacobiSmoother::SetOperator calls this, so it is required for the FGMRES case.
  void AssembleDiagonal(Vector &diag) const override
  {
    diag.SetSize(2);
    diag[0] = 4.0;
    diag[1] = 3.0;
  }

  void Mult(const Vector &x, Vector &y) const override
  {
    y.SetSize(2);
    y[0] = 4.0 * x[0] + x[1];
    y[1] = x[0] + 3.0 * x[1];
  }

  void MultTranspose(const Vector &x, Vector &y) const override { Mult(x, y); }
};

}  // namespace

// A zero residual with eps = 0 used to fall through the strict convergence test and
// divide by zero on the first iteration, returning a NaN solution vector.
TEST_CASE("CgSolver zero residual", "[iterative][Serial][Parallel]")
{
  SpdTestOperator A;
  CgSolver<Operator> ksp(Mpi::World(), 0);
  ksp.SetOperator(A);
  ksp.SetRelTol(1.0e-10);
  ksp.SetMaxIter(10);

  SECTION("Zero right-hand side")
  {
    Vector b(2), x(2);
    b = 0.0;
    x = 0.0;
    ksp.Mult(b, x);
    const auto stats = ksp.GetSolveDiagnostics();
    CHECK(stats.available);
    CHECK(stats.iterations == 0);
    CHECK(stats.converged);
    CHECK(stats.initial_residual == 0.0);
    CHECK(stats.final_residual == 0.0);
    CHECK_FALSE(stats.final_residual_is_estimate);
    CHECK(ksp.GetNumIterations() == 0);
    CHECK(ksp.GetConverged());
    CHECK_THAT(ksp.GetFinalRes(), WithinAbs(0.0, 1.0e-14));
    CHECK(std::isfinite(x[0]));
    CHECK(std::isfinite(x[1]));
  }

  SECTION("Exact initial guess")
  {
    // Regression coverage: eps > 0 here, so this passed before the zero-residual fix too.
    Vector b(2), x(2);
    b = 0.0;
    b[0] = 2.0;  // b = A x for x = (1, -2)
    b[1] = -5.0;
    x = 0.0;
    x[0] = 1.0;
    x[1] = -2.0;
    ksp.SetInitialGuess(true);
    ksp.Mult(b, x);
    const auto stats = ksp.GetSolveDiagnostics();
    CHECK(stats.available);
    CHECK(stats.iterations == 0);
    CHECK(stats.converged);
    CHECK(stats.initial_residual == 0.0);
    CHECK(stats.final_residual == 0.0);
    CHECK_FALSE(stats.final_residual_is_estimate);
    CHECK(ksp.GetNumIterations() == 0);
    CHECK(ksp.GetConverged());
    CHECK_THAT(ksp.GetFinalRes(), WithinAbs(0.0, 1.0e-14));
    CHECK_THAT(x[0], WithinAbs(1.0, 1.0e-14));
    CHECK_THAT(x[1], WithinAbs(-2.0, 1.0e-14));
  }
}

TEST_CASE("GmresSolver zero residual", "[iterative][Serial][Parallel]")
{
  SpdTestOperator A;
  GmresSolver<Operator> ksp(Mpi::World(), 0);
  ksp.SetOperator(A);
  ksp.SetRelTol(1.0e-10);
  ksp.SetMaxIter(10);

  SECTION("Zero right-hand side")
  {
    Vector b(2), x(2);
    b = 0.0;
    x = 0.0;
    ksp.Mult(b, x);
    const auto stats = ksp.GetSolveDiagnostics();
    CHECK(stats.available);
    CHECK(stats.iterations == 0);
    CHECK(stats.converged);
    CHECK(stats.initial_residual == 0.0);
    CHECK(stats.final_residual == 0.0);
    CHECK_FALSE(stats.final_residual_is_estimate);
    CHECK(ksp.GetNumIterations() == 0);
    CHECK(ksp.GetConverged());
    CHECK_THAT(ksp.GetFinalRes(), WithinAbs(0.0, 1.0e-14));
    CHECK(std::isfinite(x[0]));
    CHECK(std::isfinite(x[1]));
  }

  SECTION("Exact initial guess")
  {
    // Regression coverage: eps > 0 here, so this passed before the zero-residual fix too.
    Vector b(2), x(2);
    b = 0.0;
    b[0] = 2.0;
    b[1] = -5.0;
    x = 0.0;
    x[0] = 1.0;
    x[1] = -2.0;
    ksp.SetInitialGuess(true);
    ksp.Mult(b, x);
    const auto stats = ksp.GetSolveDiagnostics();
    CHECK(stats.available);
    CHECK(stats.iterations == 0);
    CHECK(stats.converged);
    CHECK(stats.initial_residual == 0.0);
    CHECK(stats.final_residual == 0.0);
    CHECK_FALSE(stats.final_residual_is_estimate);
    CHECK(ksp.GetNumIterations() == 0);
    CHECK(ksp.GetConverged());
    CHECK_THAT(ksp.GetFinalRes(), WithinAbs(0.0, 1.0e-14));
    CHECK_THAT(x[0], WithinAbs(1.0, 1.0e-14));
    CHECK_THAT(x[1], WithinAbs(-2.0, 1.0e-14));
  }
}

TEST_CASE("FgmresSolver zero residual", "[iterative][Serial][Parallel]")
{
  SpdTestOperator A;
  JacobiSmoother<Operator> jacobi(Mpi::World());
  jacobi.SetOperator(A);
  FgmresSolver<Operator> ksp(Mpi::World(), 0);
  ksp.SetOperator(A);
  ksp.SetPreconditioner(jacobi);
  ksp.SetRelTol(1.0e-10);
  ksp.SetMaxIter(10);

  SECTION("Zero right-hand side")
  {
    Vector b(2), x(2);
    b = 0.0;
    x = 0.0;
    ksp.Mult(b, x);
    const auto stats = ksp.GetSolveDiagnostics();
    CHECK(stats.available);
    CHECK(stats.iterations == 0);
    CHECK(stats.converged);
    CHECK(stats.initial_residual == 0.0);
    CHECK(stats.final_residual == 0.0);
    CHECK_FALSE(stats.final_residual_is_estimate);
    CHECK(ksp.GetNumIterations() == 0);
    CHECK(ksp.GetConverged());
    CHECK_THAT(ksp.GetFinalRes(), WithinAbs(0.0, 1.0e-14));
    CHECK(std::isfinite(x[0]));
    CHECK(std::isfinite(x[1]));
  }
}

// Without a preconditioner, the initial-guess path took the square root of the right-hand
// side norm, so the relative tolerance was measured against sqrt(||b||) instead of ||b||.
TEST_CASE("CgSolver initial residual with initial guess", "[iterative][Serial][Parallel]")
{
  SpdTestOperator A;
  CgSolver<Operator> ksp(Mpi::World(), 0);
  ksp.SetOperator(A);
  ksp.SetRelTol(1.0e-10);
  ksp.SetMaxIter(10);
  ksp.SetInitialGuess(true);

  Vector b(2), x(2);
  b[0] = 3.0;  // ||b|| = 5 on each rank
  b[1] = 4.0;
  x = 0.0;
  ksp.Mult(b, x);
  const double b_norm = 5.0 * std::sqrt(Mpi::Size(Mpi::World()));
  CHECK_THAT(ksp.GetInitialRes(), WithinRel(b_norm, 1.0e-14));
}

TEST_CASE("CgSolver zero residual (complex)", "[iterative][Serial][Parallel]")
{
  SpdTestOperator A;
  ComplexWrapperOperator Ac(&A, nullptr);
  CgSolver<ComplexOperator> ksp(Mpi::World(), 0);
  ksp.SetOperator(Ac);
  ksp.SetRelTol(1.0e-10);
  ksp.SetMaxIter(10);

  SECTION("Zero right-hand side")
  {
    ComplexVector b(2), x(2);
    b = 0.0;
    x = 0.0;
    ksp.Mult(b, x);
    const auto stats = ksp.GetSolveDiagnostics();
    CHECK(stats.available);
    CHECK(stats.iterations == 0);
    CHECK(stats.converged);
    CHECK(stats.initial_residual == 0.0);
    CHECK(stats.final_residual == 0.0);
    CHECK_FALSE(stats.final_residual_is_estimate);
    CHECK(ksp.GetNumIterations() == 0);
    CHECK(ksp.GetConverged());
    CHECK_THAT(ksp.GetFinalRes(), WithinAbs(0.0, 1.0e-14));
    CHECK(std::isfinite(x.Real()[0]));
    CHECK(std::isfinite(x.Real()[1]));
  }
}

TEST_CASE("CgSolver native solve diagnostics", "[iterative][Serial][Parallel]")
{
  SpdTestOperator A;
  JacobiSmoother<Operator> jacobi(Mpi::World());
  jacobi.SetOperator(A);
  CgSolver<Operator> ksp(Mpi::World(), 0);
  ksp.SetOperator(A);
  ksp.SetPreconditioner(jacobi);
  ksp.SetRelTol(1.0e-10);
  ksp.SetAbsTol(1.0e-14);
  CHECK_FALSE(ksp.GetSolveDiagnostics().available);

  Vector b(2), x(2);
  b[0] = 3.0;
  b[1] = 4.0;
  x = 0.0;
  const double reference = std::sqrt((9.0 / 4.0 + 16.0 / 3.0) * Mpi::Size(Mpi::World()));

  SECTION("Iteration exhaustion")
  {
    ksp.SetMaxIter(1);
    ksp.Mult(b, x);
    const auto stats = ksp.GetSolveDiagnostics();
    CHECK(stats.available);
    CHECK(std::string(stats.algorithm) == "cg");
    CHECK(std::string(stats.residual_norm) == "sqrt(r^T B r)");
    CHECK_THAT(stats.initial_residual, WithinRel(reference, 1.0e-14));
    CHECK_THAT(stats.reference_residual, WithinRel(reference, 1.0e-14));
    CHECK(std::string(stats.reference_residual_source) == "initial_residual");
    CHECK(stats.iterations == 1);
    CHECK(stats.maximum_iterations == 1);
    CHECK_FALSE(stats.converged);
    CHECK(stats.final_residual_is_estimate);
    CHECK(stats.final_residual == ksp.GetFinalRes());
    CHECK(stats.relative_tolerance == ksp.GetRelTol());
    CHECK(stats.absolute_tolerance == ksp.GetAbsTol());
  }

  SECTION("Convergence and RHS reference with initial guess")
  {
    ksp.SetMaxIter(10);
    ksp.Mult(b, x);
    CHECK(ksp.GetSolveDiagnostics().converged);
    CHECK(ksp.GetSolveDiagnostics().iterations == 2);

    // b = A x exactly. The initial residual is zero, while the relative stopping
    // tolerance still uses the preconditioned RHS norm as its reference.
    x[0] = 1.0;
    x[1] = -1.0;
    b[0] = 3.0;
    b[1] = -2.0;
    ksp.SetInitialGuess(true);
    ksp.Mult(b, x);
    const auto stats = ksp.GetSolveDiagnostics();
    CHECK(stats.initial_residual == 0.0);
    CHECK(stats.final_residual == 0.0);
    CHECK(std::string(stats.reference_residual_source) == "rhs");
    CHECK(stats.iterations == 0);
    CHECK(stats.converged);
    CHECK_THAT(
        stats.reference_residual,
        WithinRel(std::sqrt((9.0 / 4.0 + 4.0 / 3.0) * Mpi::Size(Mpi::World())), 1.0e-14));
  }
}

TEST_CASE("GMRES native preconditioning norm diagnostics", "[iterative][Serial][Parallel]")
{
  SpdTestOperator A;
  JacobiSmoother<Operator> jacobi(Mpi::World());
  jacobi.SetOperator(A);
  Vector b(2), x(2);
  b[0] = 3.0;
  b[1] = 4.0;
  x = 0.0;

  GmresSolver<Operator> gmres(Mpi::World(), 0);
  FgmresSolver<Operator> fgmres(Mpi::World(), 0);
  IterativeSolver<Operator> *ksp = &gmres;
  const char *algorithm = "gmres";
  const char *norm = "||r||_2";
  double initial = 5.0;
  SECTION("Left GMRES")
  {
    gmres.SetPreconditioner(jacobi);
    norm = "||B r||_2";
    initial = std::sqrt(9.0 / 16.0 + 16.0 / 9.0);
  }
  SECTION("Right GMRES")
  {
    gmres.SetPreconditioner(jacobi);
    gmres.SetPreconditionerSide(PreconditionerSide::RIGHT);
  }
  SECTION("Unpreconditioned GMRES") {}
  SECTION("FGMRES")
  {
    ksp = &fgmres;
    algorithm = "fgmres";
    fgmres.SetPreconditioner(jacobi);
  }
  ksp->SetOperator(A);
  ksp->SetRelTol(1.0e-10);
  ksp->SetMaxIter(1);
  CHECK_FALSE(ksp->GetSolveDiagnostics().available);
  ksp->Mult(b, x);
  const auto stats = ksp->GetSolveDiagnostics();
  CHECK(stats.available);
  CHECK(std::string(stats.algorithm) == algorithm);
  CHECK(std::string(stats.residual_norm) == norm);
  CHECK_THAT(stats.initial_residual,
             WithinRel(initial * std::sqrt(Mpi::Size(Mpi::World())), 1.0e-14));
  CHECK(stats.reference_residual == stats.initial_residual);
  CHECK(std::string(stats.reference_residual_source) == "initial_residual");
  CHECK(stats.final_residual == ksp->GetFinalRes());
  CHECK(stats.iterations == 1);
  CHECK_FALSE(stats.converged);
  CHECK(stats.final_residual_is_estimate);
}

}  // namespace palace
