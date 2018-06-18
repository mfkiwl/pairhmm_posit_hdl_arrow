// Copyright 2018 Delft University of Technology
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#pragma once

#include <memory>

#include "fletcher/FPGAPlatform.h"
#include "fletcher/UserCore.h"

#include "batch.hpp"

#define REUC_TOTAL_UNITS   1

#define REG_CONTROL_OFFSET  1
#define REG_HAPL_FIRSTLAST_OFFSET 8
#define REG_READ_FIRSTLAST_OFFSET 9
#define REG_X_Y_OFFSET 10
#define REG_XP_YP_OFFSET 11
#define REG_XBPP_OFFSET 12
#define REG_RESULT_OFFSET 13

/**
 * \class PairHMMUserCore
 *
 * A class to provide interaction with the regular expression matching UserCore example.
 */
class PairHMMUserCore : public fletcher::UserCore
{
 public:
  /**
   * \param platform  The platform to run the PairHMMUserCore on.
   */
  PairHMMUserCore(std::shared_ptr<fletcher::FPGAPlatform> platform);

  void set_batch_meta(t_batch& batch);

  /**
   * \brief Set arguments for the RegEx units based on first and last index
   *
   * \param first_index The first index in the column to start working on.
   * \param last_index  The last index in the column to start working on
   *                    (exclusive).
   */
  void set_arguments(uint32_t first_index, uint32_t last_index);

  /**
   * \brief Get the number of matches from the units.
   */
  void get_matches(std::vector<uint32_t>& matches);

  void control_zero();

    /**
     * \brief Get the result from FPGA
     */
    void get_result(uint32_t& result);
 private:
  /**
   * \brief Generate arguments for each of the units.
   */
  fletcher::fr_t generate_unit_arguments(uint32_t last_index,
                                                      uint32_t first_index);

};
