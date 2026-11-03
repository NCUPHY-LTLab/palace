// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: Apache-2.0

#ifndef PALACE_UTILS_ADAPTDIAGNOSTICS_HPP
#define PALACE_UTILS_ADAPTDIAGNOSTICS_HPP

#include <mfem.hpp>
#include <nlohmann/json.hpp>
#include "filesystem.hpp"

namespace palace
{

// Collective native AMR provenance. All public operations must be called by every rank.
// Element identities are local to (mesh_id, rank); they are not persistent lineage IDs.
class AdaptDiagnostics
{
  MPI_Comm comm;
  fs::path directory;
  int iteration = 0;
  int pre_elements = 0;
  nlohmann::json manifest, solve, transition, shard, terminals;

  void WriteRoot(const fs::path &path, const nlohmann::json &value) const;
  void WriteLocal(const fs::path &path, const nlohmann::json &value) const;
  nlohmann::json Snapshot(mfem::ParMesh &mesh, const std::string &mesh_id) const;
  void WriteManifest() const;
  void RegisterFile(const std::string &path);

public:
  AdaptDiagnostics(MPI_Comm comm, const fs::path &output);
  void BeginSolve(mfem::ParMesh &mesh, int iteration);
  void SetTrueDofs(long long true_dofs);
  void WriteTerminal(int terminal, const nlohmann::json &statistics);
  void SetCapacitanceTerminalOrder(const std::vector<int> &terminal_order);
  void MarkCapacitanceWritten(const std::vector<int> &terminal_order = {});
  void FinishSolve(bool completed, long long true_dofs, double indicator_norm = 0.0);
  void FailSolve();
  void BeginTransition(mfem::ParMesh &mesh, const mfem::Array<int> &marked,
                       const mfem::Vector &eta, double threshold, double theta,
                       int max_nc_levels);
  // Must be invoked immediately after GeneralRefinement, before any rebalance/update.
  void EndRefinement(mfem::ParMesh &mesh);
  void FinishTransition(mfem::ParMesh &mesh);
};

}  // namespace palace

#endif
