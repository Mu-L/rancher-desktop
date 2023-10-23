/*
Copyright © 2023 SUSE LLC

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
package host_test

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rancher-sandbox/rancher-desktop/src/go/wsl-helper/pkg/host"
	"github.com/stretchr/testify/assert"
)

var hostsFileContent = `# This file was automatically generated by WSL. To stop automatic generation of this file, add the following entry to /etc/wsl.conf:
	# [network]
	# generateHosts = false
	127.0.0.1       localhost
	127.0.1.1       DESKTOP-TEST.        DESKTOP-TEST
	10.0.0.197      test.proxy.me

	# The following lines are desirable for IPv6 capable hosts
	::1     ip6-localhost ip6-loopback
	fe00::0 ip6-localhost
	ff00::0 ip6-prefix
	ff02::1 ip6-nodes
	ff02::2 ip6-routers`

func TestAppendHostsFile(t *testing.T) {
	tempHostsFile, err := createTempHostFile(t)
	assert.NoError(t, err)

	content, err := os.ReadFile(tempHostsFile)
	assert.NoError(t, err)

	assert.Contains(t, string(content), host.BeginConfig)
	assert.Contains(t, string(content), fmt.Sprintf("%s %s", host.GatewayIP, host.GatewayDomain))
	assert.Contains(t, string(content), host.EndConfig)
}

func TestAppendHostsFileAlreadyExist(t *testing.T) {
	tempHostsFile, err := createTempHostFile(t)
	assert.NoError(t, err)

	origContent, err := os.ReadFile(tempHostsFile)
	assert.NoError(t, err)

	err = host.AppendHostsFile(
		[]string{fmt.Sprintf("%s %s", host.GatewayIP, host.GatewayDomain)},
		tempHostsFile)
	assert.NoError(t, err)

	afterContent, err := os.ReadFile(tempHostsFile)
	assert.NoError(t, err)

	assert.Equal(t, origContent, afterContent)

	origLines := strings.Split(string(origContent), "\n")
	afterLines := strings.Split(string(afterContent), "\n")

	assert.Equal(t, len(origLines), len(afterLines))
}

func TestRemoveHostFileEntry(t *testing.T) {
	tempHostsFile, err := createTempHostFile(t)
	assert.NoError(t, err)

	assert.NoError(t, host.RemoveHostsFileEntry(tempHostsFile))

	content, err := os.ReadFile(tempHostsFile)
	assert.NoError(t, err)

	assert.NotContains(t, string(content), host.BeginConfig)
	assert.NotContains(t, string(content), fmt.Sprintf("%s %s", host.GatewayIP, host.GatewayDomain))
	assert.NotContains(t, string(content), host.EndConfig)
}

func TestRemoveHostFileEntryNotExist(t *testing.T) {
	tempDir := t.TempDir()
	tempHostsFile := filepath.Join(tempDir, "hosts")

	hostFileBytes := []byte(hostsFileContent)
	err := os.WriteFile(tempHostsFile, hostFileBytes, 0644)
	assert.NoError(t, err)

	assert.NoError(t, host.RemoveHostsFileEntry(tempHostsFile))

	content, err := os.ReadFile(tempHostsFile)
	assert.NoError(t, err)

	assert.Equal(t, hostFileBytes, content)
}

func createTempHostFile(t *testing.T) (string, error) {
	tempDir := t.TempDir()
	tempHostsFile := filepath.Join(tempDir, "hosts")

	err := os.WriteFile(tempHostsFile, []byte(hostsFileContent), 0644)
	if err != nil {
		return "", err
	}

	err = host.AppendHostsFile(
		[]string{fmt.Sprintf("%s %s", host.GatewayIP, host.GatewayDomain)},
		tempHostsFile)

	if err != nil {
		return "", err
	}

	return tempHostsFile, nil
}
