// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

#include "adaptdiagnostics.hpp"

#include <algorithm>
#include <fstream>
#include <stdexcept>
#include "communication.hpp"
#include "outputdir.hpp"

namespace palace
{
namespace
{
using json = nlohmann::json;

void AtomicJSON(const fs::path &path, const json &value)
{
  auto temporary = path;
  temporary += ".tmp";
  if (fs::is_symlink(fs::symlink_status(temporary)))
  {
    throw std::runtime_error("AMR diagnostics temporary file must not be a symlink");
  }
  {
    std::ofstream stream;
    stream.exceptions(std::ios::failbit | std::ios::badbit);
    stream.open(temporary);
    stream << value.dump(2) << '\n';
    stream.close();
  }
  fs::rename(temporary, path);
}

std::string SolvePath(int iteration)
{
  return fmt::format("solves/solve-{}.json", iteration);
}
std::string TransitionPath(int iteration)
{
  return fmt::format("transitions/transition-{}.json", iteration);
}
}  // namespace

AdaptDiagnostics::AdaptDiagnostics(MPI_Comm comm, const fs::path &output)
  : comm(comm), directory(output / "amr-diagnostics")
{
  ApplyOnEachNodeFilesystem(
      comm, "Creating AMR diagnostics directories",
      [&]()
      {
        if (fs::is_symlink(fs::symlink_status(directory)))
        {
          throw std::runtime_error("AMR diagnostics directory must not be a symlink");
        }
        for (const auto *name : {"solves", "transitions", "meshes", "terminals"})
        {
          if (fs::is_symlink(fs::symlink_status(directory / name)))
          {
            throw std::runtime_error("AMR diagnostics subdirectory must not be a symlink");
          }
          fs::create_directories(directory / name);
        }
      });
  manifest = {{"schema", "palace.amr_diagnostics"},
              {"schema_version", 1},
              {"coordinate_units", "nondimensional"},
              {"mpi_size", Mpi::Size(comm)},
              {"solves", json::array()},
              {"transitions", json::array()},
              {"files", json::array()}};
  manifest["record_type"] = "manifest";
  WriteManifest();
}

void AdaptDiagnostics::WriteRoot(const fs::path &path, const json &value) const
{
  ApplyOnRootFilesystem(comm, "Writing AMR diagnostics",
                        [&]()
                        {
                          json record = value;
                          record["schema"] = "palace.amr_diagnostics";
                          record["schema_version"] = 1;
                          AtomicJSON(directory / path, record);
                        });
}

void AdaptDiagnostics::WriteLocal(const fs::path &path, const json &value) const
{
  std::string error;
  try
  {
    json record = value;
    record["schema"] = "palace.amr_diagnostics";
    record["schema_version"] = 1;
    record["record_type"] = "rank";
    AtomicJSON(directory / path, record);
  }
  catch (const std::exception &e)
  {
    error = e.what();
  }
  internal::AbortOnNodeFilesystemError(comm, "Writing AMR rank diagnostics", error);
}

void AdaptDiagnostics::WriteManifest() const
{
  WriteRoot("manifest.json", manifest);
}

void AdaptDiagnostics::RegisterFile(const std::string &path)
{
  auto &files = manifest["files"];
  if (std::find(files.begin(), files.end(), json(path)) == files.end())
  {
    files.push_back(path);
  }
}

nlohmann::json AdaptDiagnostics::Snapshot(mfem::ParMesh &mesh,
                                          const std::string &mesh_id) const
{
  const auto path = fmt::format("meshes/{}-rank-{}.mesh", mesh_id, Mpi::Rank(comm));
  std::string error;
  try
  {
    auto temporary = directory / (path + ".tmp");
    if (fs::is_symlink(fs::symlink_status(temporary)))
    {
      throw std::runtime_error("AMR mesh temporary file must not be a symlink");
    }
    std::ofstream stream;
    stream.exceptions(std::ios::failbit | std::ios::badbit);
    stream.open(temporary);
    stream.precision(17);
    mesh.ParPrint(stream);
    stream.close();
    fs::rename(temporary, directory / path);
  }
  catch (const std::exception &e)
  {
    error = e.what();
  }
  internal::AbortOnNodeFilesystemError(comm, "Writing AMR mesh snapshot", error);
  json paths = json::array();
  for (int rank = 0; rank < Mpi::Size(comm); rank++)
  {
    paths.push_back(fmt::format("meshes/{}-rank-{}.mesh", mesh_id, rank));
  }
  return paths;
}

void AdaptDiagnostics::BeginSolve(mfem::ParMesh &mesh, int next_iteration)
{
  iteration = next_iteration;
  terminals = json::object();
  const auto mesh_id = fmt::format("solve-{}", iteration);
  solve = {{"record_type", "solve"},
           {"iteration", iteration},
           {"mesh_id", mesh_id},
           {"state", "started"},
           {"owned_global_cells", mesh.GetGlobalNE()},
           {"true_dofs", nullptr},
           {"capacitance_written", false},
           {"capacitance_iteration", nullptr},
           {"capacitance_terminal_order", nullptr},
           {"terminal_records", json::array()}};
  solve["mesh_paths"] = json::array();
  for (int rank = 0; rank < Mpi::Size(comm); rank++)
  {
    solve["mesh_paths"].push_back(fmt::format("meshes/{}-rank-{}.mesh", mesh_id, rank));
  }
  WriteRoot(SolvePath(iteration), solve);
  RegisterFile(SolvePath(iteration));
  for (const auto &path : solve["mesh_paths"])
  {
    RegisterFile(path.get<std::string>());
  }
  manifest["solves"].push_back(SolvePath(iteration));
  WriteManifest();
  // Publish the attempted identity before snapshot IO as well as before the solve, so
  // interruption during a large mesh write leaves a discoverable started attempt.
  Snapshot(mesh, mesh_id);
}

void AdaptDiagnostics::SetTrueDofs(long long true_dofs)
{
  solve["true_dofs"] = true_dofs;
  WriteRoot(SolvePath(iteration), solve);
}

void AdaptDiagnostics::WriteTerminal(int terminal, const json &statistics)
{
  const auto path = fmt::format("terminals/solve-{}-terminal-{}.json", iteration, terminal);
  const auto key = std::to_string(terminal);
  if (!terminals.contains(key))
  {
    terminals[key] = {{"main", {{"available", false}}},
                      {"recovery", {{"available", false}}}};
  }
  terminals[key].merge_patch(statistics);
  json record = {{"record_type", "terminal"},
                 {"iteration", iteration},
                 {"mesh_id", solve.at("mesh_id")},
                 {"terminal", terminal},
                 {"statistics", terminals[key]}};
  WriteRoot(path, record);
  RegisterFile(path);
  WriteManifest();
  auto &records = solve["terminal_records"];
  if (std::find(records.begin(), records.end(), json(path)) == records.end())
  {
    records.push_back(path);
  }
  WriteRoot(SolvePath(iteration), solve);
}

void AdaptDiagnostics::SetCapacitanceTerminalOrder(const std::vector<int> &terminal_order)
{
  solve["capacitance_terminal_order"] = terminal_order;
  WriteRoot(SolvePath(iteration), solve);
}

void AdaptDiagnostics::MarkCapacitanceWritten(const std::vector<int> &terminal_order)
{
  solve["capacitance_terminal_order"] = terminal_order;
  solve["capacitance_written"] = true;
  solve["capacitance_iteration"] = iteration;
  WriteRoot(SolvePath(iteration), solve);
}

void AdaptDiagnostics::FinishSolve(bool completed, long long true_dofs,
                                   double indicator_norm)
{
  solve["indicator_norm"] = indicator_norm;
  solve["indicator_semantics"] =
      "native ZZ: eta_Kn=sqrt(estimates_Kn*(Et_n>0 ? 0.5/Et_n : 1.0)); estimates include "
      "material weighting; elementwise RMS across nsamples excitations; "
      "E=sqrt((1/nsamples)*sum_n sum_K eta_Kn^2)";
  solve["state"] = completed ? "completed" : "failed";
  solve["true_dofs"] = true_dofs;
  WriteRoot(SolvePath(iteration), solve);
}

void AdaptDiagnostics::FailSolve()
{
  solve["state"] = "failed";
  WriteRoot(SolvePath(iteration), solve);
}

void AdaptDiagnostics::BeginTransition(mfem::ParMesh &mesh, const mfem::Array<int> &marked,
                                       const mfem::Vector &eta, double threshold,
                                       double theta, int max_nc_levels)
{
  pre_elements = mesh.GetNE();
  double sums[2] = {};
  const auto *values = eta.HostRead();
  for (int i = 0; i < eta.Size(); i++)
  {
    sums[0] += values[i] * values[i];
  }
  json marked_ids = json::array();
  for (auto id : marked)
  {
    marked_ids.push_back(id);
    sums[1] += values[id] * values[id];
  }
  Mpi::GlobalSum(2, sums, comm);
  transition = {
      {"record_type", "transition"},
      {"pre_iteration", iteration},
      {"next_iteration", iteration + 1},
      {"pre_mesh_id", fmt::format("solve-{}", iteration)},
      {"refined_mesh_id", fmt::format("refined-{}", iteration)},
      {"next_mesh_id", fmt::format("solve-{}", iteration + 1)},
      {"state", "started"},
      {"threshold", threshold},
      {"theta_requested", theta},
      {"eta_squared_total", sums[0]},
      {"eta_squared_marked", sums[1]},
      {"marked_error_fraction", sums[0] == 0.0 ? json(nullptr) : json(sums[1] / sums[0])},
      {"marked_error_fraction_reason",
       sums[0] == 0.0 ? json("zero_total_indicator") : json(nullptr)},
      {"mesh_conformity", mesh.Nonconforming() ? "NC" : "C"},
      {"max_nc_levels", max_nc_levels},
      {"owned_global_cells_pre", mesh.GetGlobalNE()}};
  shard = {{"rank", Mpi::Rank(comm)},
           {"pre_mesh_id", transition["pre_mesh_id"]},
           {"refined_mesh_id", transition["refined_mesh_id"]},
           {"owned_cells_pre", pre_elements},
           {"marked", marked_ids}};
  WriteRoot(TransitionPath(iteration), transition);
  RegisterFile(TransitionPath(iteration));
  manifest["transitions"].push_back(TransitionPath(iteration));
  WriteManifest();
}

void AdaptDiagnostics::EndRefinement(mfem::ParMesh &mesh)
{
  const auto &embeddings = mesh.GetRefinementTransforms().embeddings;
  std::vector<int> children(pre_elements, 0);
  json mapping = json::array();
  for (int fine = 0; fine < mesh.GetNE(); fine++)
  {
    const auto &embedding = embeddings[fine];
    if (embedding.ghost)
    {
      continue;
    }
    MFEM_VERIFY(embedding.parent >= 0 && embedding.parent < pre_elements,
                "AMR refinement parent outside the pre-refinement local mesh!");
    children[embedding.parent]++;
    mapping.push_back({{"fine", fine}, {"coarse", embedding.parent}});
  }
  std::vector<unsigned char> marked_membership(pre_elements, 0);
  for (const auto &marked : shard["marked"])
  {
    marked_membership[marked.get<int>()] = 1;
  }
  json parents = json::array();
  long long counts[3] = {static_cast<long long>(shard["marked"].size()), 0, 0};
  for (int parent = 0; parent < pre_elements; parent++)
  {
    if (children[parent] > 1)
    {
      parents.push_back(parent);
      counts[1]++;
      if (!marked_membership[parent])
      {
        counts[2]++;
      }
    }
  }
  shard["fine_to_coarse"] = mapping;
  shard["refined_parents"] = parents;
  shard["owned_cells_post_refinement"] = mesh.GetNE();
  shard["marked_count"] = counts[0];
  shard["refined_parent_count"] = counts[1];
  shard["extra_refined_parent_count"] = counts[2];
  Mpi::GlobalSum(3, counts, comm);
  transition["marked_count"] = counts[0];
  transition["refined_parent_count"] = counts[1];
  transition["extra_refined_parent_count"] = counts[2];
  transition["owned_global_cells_post_refinement"] = mesh.GetGlobalNE();
  transition["refined_mesh_paths"] = json::array();
  for (int rank = 0; rank < Mpi::Size(comm); rank++)
  {
    const auto path = fmt::format("meshes/{}-rank-{}.mesh",
                                  transition["refined_mesh_id"].get<std::string>(), rank);
    transition["refined_mesh_paths"].push_back(path);
    RegisterFile(path);
  }
  WriteManifest();
  Snapshot(mesh, transition["refined_mesh_id"]);
  const auto path =
      fmt::format("transitions/transition-{}-rank-{}.json", iteration, Mpi::Rank(comm));
  WriteLocal(path, shard);
  transition["rank_records"] = json::array();
  for (int rank = 0; rank < Mpi::Size(comm); rank++)
  {
    const auto path =
        fmt::format("transitions/transition-{}-rank-{}.json", iteration, rank);
    transition["rank_records"].push_back(path);
    RegisterFile(path);
  }
  WriteManifest();
  transition["state"] = "refined";
  WriteRoot(TransitionPath(iteration), transition);
}

void AdaptDiagnostics::FinishTransition(mfem::ParMesh &mesh)
{
  transition["owned_global_cells_post_rebalance"] = mesh.GetGlobalNE();
  transition["state"] = "completed";
  WriteRoot(TransitionPath(iteration), transition);
}

}  // namespace palace
