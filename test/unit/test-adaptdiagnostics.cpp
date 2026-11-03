// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

#include <algorithm>
#include <fstream>
#include <catch2/catch_test_macros.hpp>
#include <nlohmann/json.hpp>
#include "drivers/basesolver.hpp"
#include "fixtures.hpp"
#include "utils/adaptdiagnostics.hpp"
#include "utils/communication.hpp"

using namespace palace;

namespace
{
using json = nlohmann::json;
json ReadJSON(const fs::path &path)
{
  std::ifstream input(path);
  return json::parse(input);
}
std::string ReadBytes(const fs::path &path)
{
  std::ifstream input(path);
  return {std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>()};
}

void RefineAndRecord(AdaptDiagnostics &diagnostics, mfem::ParMesh &mesh,
                     const mfem::Array<int> &marked, int cap)
{
  mfem::Vector eta(mesh.GetNE());
  eta = 1.0;
  diagnostics.BeginTransition(mesh, marked, eta, 1.0, 0.5, cap);
  mesh.GeneralRefinement(marked, -1, cap);
  diagnostics.EndRefinement(mesh);
  diagnostics.FinishTransition(mesh);
}

void CheckOwnedMapping(const fs::path &directory, mfem::ParMesh &mesh, int iteration)
{
  const auto shard = ReadJSON(
      directory / "amr-diagnostics" / "transitions" /
      fmt::format("transition-{}-rank-{}.json", iteration, Mpi::Rank(mesh.GetComm())));
  // NC transform arrays may contain ghost embeddings; only owned mesh leaves belong here.
  REQUIRE(shard.at("fine_to_coarse").size() == std::size_t(mesh.GetNE()));
  for (const auto &entry : shard.at("fine_to_coarse"))
  {
    CHECK(entry.at("fine").get<int>() < mesh.GetNE());
    CHECK(entry.at("coarse").get<int>() < shard.at("owned_cells_pre").get<int>());
  }
}
}  // namespace

TEST_CASE_METHOD(palace::test::SharedTempDir,
                 "AMR diagnostics count conforming closure parents before rebalance",
                 "[adaptdiagnostics][Serial][Parallel]")
{
  MPI_Comm comm = MPI_COMM_WORLD;
  REQUIRE(Mpi::Size(comm) <= 2);
  auto serial = mfem::Mesh::MakeCartesian2D(1, 1, mfem::Element::TRIANGLE);
  int partition[] = {0, Mpi::Size(comm) - 1};
  mfem::ParMesh mesh(comm, serial, partition);
  AdaptDiagnostics diagnostics(comm, temp_dir);
  diagnostics.BeginSolve(mesh, 1);
  diagnostics.FinishSolve(true, 4, 1.0);
  mfem::Array<int> marked;
  if (Mpi::Root(comm))
  {
    marked.Append(0);
  }
  RefineAndRecord(diagnostics, mesh, marked, 0);
  CheckOwnedMapping(temp_dir, mesh, 1);
  if (Mpi::Root(comm))
  {
    const auto record =
        ReadJSON(temp_dir / "amr-diagnostics/transitions/transition-1.json");
    CHECK(record.at("mesh_conformity") == "C");
    CHECK(record.at("owned_global_cells_pre") == 2);
    CHECK(record.at("marked_count") == 1);
    CHECK(record.at("refined_parent_count") == 2);
    CHECK(record.at("extra_refined_parent_count") == 1);
    CHECK(record.at("marked_error_fraction") == 0.5);
  }
}

TEST_CASE_METHOD(palace::test::SharedTempDir,
                 "AMR diagnostics count NC level propagation and exclude ghosts",
                 "[adaptdiagnostics][Serial][Parallel]")
{
  MPI_Comm comm = MPI_COMM_WORLD;
  REQUIRE(Mpi::Size(comm) <= 2);
  auto serial =
      mfem::Mesh::MakeCartesian2D(2, 1, mfem::Element::QUADRILATERAL, true, 2.0, 1.0);
  serial.EnsureNCMesh();
  int partition[] = {0, Mpi::Size(comm) - 1};
  mfem::ParMesh mesh(comm, serial, partition);
  AdaptDiagnostics diagnostics(comm, temp_dir);
  diagnostics.BeginSolve(mesh, 1);
  mfem::Array<int> marked;
  if (Mpi::Root(comm))
  {
    marked.Append(0);
  }
  RefineAndRecord(diagnostics, mesh, marked, 1);
  CHECK(mesh.GetGlobalNE() == 5);
  CheckOwnedMapping(temp_dir, mesh, 1);
  diagnostics.BeginSolve(mesh, 2);
  marked.SetSize(0);
  for (int i = 0; i < mesh.GetNE(); i++)
  {
    mfem::Vector center;
    mesh.GetElementCenter(i, center);
    if (center[0] == 0.75 && center[1] == 0.25)
    {
      marked.Append(i);
    }
  }
  RefineAndRecord(diagnostics, mesh, marked, 1);
  CHECK(mesh.GetGlobalNE() == 11);
  CheckOwnedMapping(temp_dir, mesh, 2);
  if (Mpi::Root(comm))
  {
    const auto record =
        ReadJSON(temp_dir / "amr-diagnostics/transitions/transition-2.json");
    CHECK(record.at("mesh_conformity") == "NC");
    CHECK(record.at("max_nc_levels") == 1);
    CHECK(record.at("marked_count") == 1);
    CHECK(record.at("refined_parent_count") == 2);
    CHECK(record.at("extra_refined_parent_count") == 1);
  }
}

TEST_CASE_METHOD(palace::test::SharedTempDir,
                 "AMR diagnostics durably attribute attempts and preserve archive bytes",
                 "[adaptdiagnostics][Serial][Parallel]")
{
  MPI_Comm comm = MPI_COMM_WORLD;
  auto serial = mfem::Mesh::MakeCartesian2D(2, 1, mfem::Element::QUADRILATERAL);
  serial.EnsureNCMesh();
  mfem::ParMesh mesh(comm, serial);
  AdaptDiagnostics diagnostics(comm, temp_dir);
  diagnostics.BeginSolve(mesh, 1);
  if (Mpi::Root(comm))
  {
    const auto manifest = ReadJSON(temp_dir / "amr-diagnostics/manifest.json");
    CHECK(manifest.at("solves") == json::array({"solves/solve-1.json"}));
    const auto &files = manifest.at("files");
    CHECK(files.size() == std::size_t(1 + Mpi::Size(comm)));
    CHECK(std::find(files.begin(), files.end(), json("manifest.json")) == files.end());
    CHECK(std::find(files.begin(), files.end(), json("solves/solve-1.json")) !=
          files.end());
    CHECK(ReadJSON(temp_dir / "amr-diagnostics/solves/solve-1.json").at("state") ==
          "started");
  }
  diagnostics.WriteTerminal(7, {{"main", {{"available", true}, {"converged", true}}}});
  diagnostics.WriteTerminal(7, {{"recovery", {{"available", true}, {"converged", false}}}});
  diagnostics.MarkCapacitanceWritten({7, 9});
  diagnostics.FinishSolve(true, 8, 0.25);
  if (Mpi::Root(comm))
  {
    std::ofstream(temp_dir / "palace.json") << "{\"Problem\":{\"Iteration\":1}}\n";
    std::ofstream(temp_dir / "C.csv") << "native capacitance bytes\n";
  }
  Mpi::Barrier(comm);
  SaveIteration(comm, temp_dir, 1, 1, true);
  const auto archived_c = ReadBytes(temp_dir / "iteration1/C.csv");
  const auto archived_meta = ReadBytes(temp_dir / "iteration1/palace.json");
  diagnostics.BeginSolve(mesh, 2);
  diagnostics.FailSolve();
  if (Mpi::Root(comm))
  {
    const auto manifest = ReadJSON(temp_dir / "amr-diagnostics/manifest.json");
    CHECK(manifest.at("files").size() == std::size_t(3 + 2 * Mpi::Size(comm)));
    for (const auto &path : manifest.at("files"))
    {
      CHECK(fs::is_regular_file(temp_dir / "amr-diagnostics" / path.get<std::string>()));
    }
    CHECK_FALSE(fs::is_symlink(temp_dir / "amr-diagnostics"));
    CHECK_FALSE(fs::exists(temp_dir / "iteration1/amr-diagnostics"));
    CHECK(ReadBytes(temp_dir / "iteration1/C.csv") == archived_c);
    CHECK(ReadBytes(temp_dir / "iteration1/palace.json") == archived_meta);
    const auto failed = ReadJSON(temp_dir / "amr-diagnostics/solves/solve-2.json");
    CHECK(failed.at("state") == "failed");
    CHECK(failed.at("capacitance_written") == false);
    CHECK(failed.at("capacitance_iteration").is_null());
    const auto first = ReadJSON(temp_dir / "amr-diagnostics/solves/solve-1.json");
    CHECK(first.at("capacitance_terminal_order") == json::array({7, 9}));
    const auto terminal =
        ReadJSON(temp_dir / "amr-diagnostics/terminals/solve-1-terminal-7.json");
    CHECK(terminal.at("statistics").at("main").at("converged") == true);
    CHECK(terminal.at("statistics").at("recovery").at("converged") == false);
  }
}
