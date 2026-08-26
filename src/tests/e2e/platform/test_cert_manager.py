#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Copyright (C) 2024-2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0

import allure
import kr8s


@allure.testcase("IEASG-T669")
def test_cert_manager_installed():
    deploys = list(kr8s.get("deployments", namespace="cert-manager",
                            label_selector={"app.kubernetes.io/name": "cert-manager"}))
    assert len(deploys) > 0, "cert-manager not installed"


@allure.testcase("IEASG-T670")
def test_cert_manager_webhook_ready():
    deploy = list(kr8s.get("deployments", namespace="cert-manager",
                           field_selector={"metadata.name": "cert-manager-webhook"}))[0]
    assert (deploy.status.readyReplicas or 0) >= 1
