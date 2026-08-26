#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Copyright (C) 2024-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

import allure
import kr8s


@allure.testcase("IEASG-T680")
def test_keycloak_operator_ready():
    deploys = list(kr8s.get("deployments", namespace="keycloak",
                            field_selector={"metadata.name": "keycloak-operator"}))
    assert len(deploys) > 0
    assert (deploys[0].status.readyReplicas or 0) >= 1


@allure.testcase("IEASG-T681")
def test_keycloak_statefulset_ready():
    sts = list(kr8s.get("statefulsets", namespace="keycloak",
                        field_selector={"metadata.name": "keycloak"}))[0]
    assert (sts.status.readyReplicas or 0) >= 1
