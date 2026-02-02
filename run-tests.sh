#!/bin/bash

##############################################################################
# Script to run Camel CICS integration tests
# Clones fuse-components repository and runs camel-cics tests
##############################################################################

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Configuration
DEFAULT_BRANCH="camel-4.14.2-branch"
DEFAULT_REPO_TYPE="middlestream"
MIDDLESTREAM_REPO_URL="https://github.com/jboss-fuse/fuse-components.git"
DOWNSTREAM_REPO_URL="https://gitlab.cee.redhat.com/pnc-workspace/jboss-fuse/fuse-components.git"
WORK_DIR="/tmp/camel-ibm-cics-test"
REPO_DIR="$WORK_DIR/fuse-components"
MODULE_DIR="camel-cics"
CICS_IMAGE="images.paas.redhat.com/fuseqe/ibm-cicstg-container-linux-x86-trial:10.1"

# Global variables for arguments
BRANCH=""
MAVEN_ARGS=""
MAVEN_SETTINGS=""
REPO_TYPE=""

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [BRANCH] [MAVEN_ARGS]

Arguments:
    BRANCH          Git branch to checkout (default: $DEFAULT_BRANCH)
    MAVEN_ARGS      Additional Maven arguments (optional)

Options:
    -s, --settings FILE           Path to custom Maven settings.xml file
    -r, --repo-type TYPE          Repository type: 'middlestream' or 'downstream' (default: $DEFAULT_REPO_TYPE)
    -h, --help                    Show this help message

Examples:
    $0                              # Use default branch and middlestream repo
    $0 camel-4.14.2-branch          # Specific branch
    $0 camel-4.14.2-branch "-X"     # With Maven debug output
    $0 camel-4.14.2-branch "-Dtest=CICSGatwayTest"  # Run specific test
    $0 camel-4.14.2-branch "-Dtest=CICSGatwayTest#testSimpleECI"  # Run specific test method
    $0 --settings ~/.m2/my-settings.xml camel-4.14.2-branch  # Custom settings
    $0 -s /path/to/settings.xml     # Custom settings with default branch
    $0 --repo-type downstream camel-4.14.2-branch  # Use downstream repository
    $0 -r downstream                # Use downstream repo with defaults
    $0 --repo-type downstream --settings ~/.m2/settings.xml camel-4.14.2-branch  # All together
    $0 --settings ~/.m2/settings.xml camel-4.14.2-branch "-Dtest=CICSGatwayTest#testSimpleECI"  # All together

Environment Variables:
    SKIP_CLONE      Set to 'true' to skip git clone (use existing repo)
    MAVEN_OPTS      Additional Maven JVM options

Working Directory:
    The repository will be cloned to: $WORK_DIR/fuse-components
    This keeps test artifacts separate from the current directory.

Available Branches:
    - camel-4.14.2-branch (default)
    - camel-4.8-branch
    - main

EOF
}

check_prerequisites() {
    print_step "Checking prerequisites..."

    # Check Java
    if ! command -v java &> /dev/null; then
        print_error "Java is not installed or not in PATH"
        exit 1
    fi
    JAVA_VERSION=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}' | cut -d'.' -f1)
    if [ "$JAVA_VERSION" -lt 17 ]; then
        print_error "Java 17 or later is required (found version $JAVA_VERSION)"
        exit 1
    fi
    print_info "Java version: $(java -version 2>&1 | head -n 1)"

    # Check Maven
    if ! command -v mvn &> /dev/null; then
        print_error "Maven is not installed or not in PATH"
        exit 1
    fi
    print_info "Maven version: $(mvn -version | head -n 1)"

    # Check Git
    if ! command -v git &> /dev/null; then
        print_error "Git is not installed or not in PATH"
        exit 1
    fi

    # Check Docker
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed or not in PATH"
        print_warn "Testcontainers requires Docker to run CICS TG container"
        exit 1
    fi
    print_info "Docker version: $(docker --version)"

    echo ""
}

check_ctg_client() {
    print_step "Checking IBM CTG Client JAR installation..."

    CTG_JAR_PATH="$HOME/.m2/repository/com/ibm/ctgclient/9.2/ctgclient-9.2.jar"

    if [ -f "$CTG_JAR_PATH" ]; then
        print_info "IBM CTG Client JAR found: $CTG_JAR_PATH"
        echo ""
        return
    fi

    print_warn "IBM CTG Client JAR not found in local Maven repository"
    print_warn "Expected location: $CTG_JAR_PATH"
    echo ""

    # Check if CICS container is running
    if docker ps | grep -q "cics-ctg-container"; then
        print_info "CICS TG container is running. Attempting automatic installation..."
        echo ""

        # Create temporary directory for extraction
        TEMP_JAR_FILE="/tmp/ctgclient-9.2-$$.jar"

        print_step "Step 1: Extracting CTG JAR from container..."
        # Try to find the CTG JAR in the container
        CTG_JAR_IN_CONTAINER=$(docker exec cics-ctg-container find /opt/ibm/cicstg/classes -name "ctgclient.jar" 2>/dev/null | head -1)

        if [ -z "$CTG_JAR_IN_CONTAINER" ]; then
            # Try alternative naming
            CTG_JAR_IN_CONTAINER=$(docker exec cics-ctg-container find /opt/ibm/cicstg/classes -name "*ctg*.jar" 2>/dev/null | grep -i client | head -1)
        fi

        if [ -z "$CTG_JAR_IN_CONTAINER" ]; then
            print_error "Could not find CTG client JAR in container"
            print_info "Searched in: /opt/ibm/cicstg/classes"
            echo ""
            print_info "Manual installation required. See README.md for details."
            exit 1
        fi

        print_info "Found CTG JAR in container: $CTG_JAR_IN_CONTAINER"

        # Copy JAR from container
        if docker cp "cics-ctg-container:$CTG_JAR_IN_CONTAINER" "$TEMP_JAR_FILE"; then
            print_info "Successfully extracted CTG JAR to: $TEMP_JAR_FILE"
        else
            print_error "Failed to copy CTG JAR from container"
            exit 1
        fi

        echo ""
        print_step "Step 2: Installing to local Maven repository..."

        # Install to Maven local repository
        if mvn install:install-file \
            -DgroupId=com.ibm \
            -DartifactId=ctgclient \
            -Dversion=9.2 \
            -Dpackaging=jar \
            -Dfile="$TEMP_JAR_FILE" -q; then
            print_info "Successfully installed CTG Client JAR to Maven repository"
            print_info "Location: $CTG_JAR_PATH"

            # Clean up temp file
            rm -f "$TEMP_JAR_FILE"
        else
            print_error "Failed to install CTG JAR to Maven repository"
            rm -f "$TEMP_JAR_FILE"
            exit 1
        fi

    else
        print_error "CICS TG container is not running"
        echo ""
        print_info "To install IBM CTG Client JAR, you need to:"
        echo ""
        print_info "1. Start the CICS TG container:"
        print_info "   ./run-cics-container.sh run"
        echo ""
        print_info "2. Re-run this script:"
        print_info "   $0"
        echo ""
        print_info "The script will automatically extract and install the JAR from the container."
        echo ""
        exit 1
    fi

    echo ""
}

clone_repository() {
    # Determine which repository URL to use based on repo type
    local REPO_URL
    if [ "$REPO_TYPE" = "downstream" ]; then
        REPO_URL="$DOWNSTREAM_REPO_URL"
        print_info "Using downstream repository"
    else
        REPO_URL="$MIDDLESTREAM_REPO_URL"
        print_info "Using middlestream repository"
    fi

    # Create work directory if it doesn't exist
    if [ ! -d "$WORK_DIR" ]; then
        print_info "Creating work directory: $WORK_DIR"
        mkdir -p "$WORK_DIR"
    fi

    if [ "${SKIP_CLONE}" = "true" ]; then
        print_info "Skipping repository clone (SKIP_CLONE=true)"
        if [ ! -d "$REPO_DIR" ]; then
            print_error "Repository directory '$REPO_DIR' not found"
            exit 1
        fi
        return
    fi

    if [ -d "$REPO_DIR" ]; then
        print_warn "Repository directory '$REPO_DIR' already exists"
        echo -n "Do you want to remove it and clone fresh? (y/N): "
        read -r response
        if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            print_info "Removing existing repository..."
            rm -rf "$REPO_DIR"
        else
            print_info "Using existing repository (will fetch and checkout branch)"
            cd "$REPO_DIR"
            print_step "Fetching latest changes..."
            git fetch origin
            print_step "Checking out branch: $BRANCH"
            git checkout "$BRANCH"
            git pull origin "$BRANCH"
            cd - > /dev/null
            return
        fi
    fi

    print_step "Cloning repository..."
    print_info "URL: $REPO_URL"
    print_info "Branch: $BRANCH"
    print_info "Destination: $REPO_DIR"

    git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"

    if [ $? -eq 0 ]; then
        print_info "Repository cloned successfully"
    else
        print_error "Failed to clone repository"
        exit 1
    fi
}

check_cics_image() {
    print_step "Checking CICS TG container image..."

    if docker images | grep -q "ibm-cicstg-container"; then
        print_info "CICS TG image found locally"
        docker images | grep ibm-cicstg-container
    else
        print_warn "CICS TG image not found locally"
        print_info "Testcontainers will pull it automatically, or you can pull it now:"
        print_info "  docker pull $CICS_IMAGE"
        echo ""
    fi
}

update_test_image_version() {
    # Skip version check if using local container (we'll replace the file anyway)
    if docker ps | grep -q "cics-ctg-container"; then
        print_info "Using local CICS container - skipping image version check"
        echo ""
        return
    fi

    print_step "Checking test configuration for image version..."

    TEST_FILE="$REPO_DIR/$MODULE_DIR/src/test/java/com/redhat/camel/component/cics/AbstractCICSContainerizedTest.java"

    if [ -f "$TEST_FILE" ]; then
        CURRENT_IMAGE=$(grep -oP 'new GenericContainer<>\("\K[^"]+' "$TEST_FILE" || echo "not found")
        print_info "Current test image: $CURRENT_IMAGE"
        print_info "Expected image: $CICS_IMAGE"

        if [[ "$CURRENT_IMAGE" != "$CICS_IMAGE" ]]; then
            print_warn "Image version mismatch detected!"
            print_warn "The test uses: $CURRENT_IMAGE"
            print_warn "You have: $CICS_IMAGE"
            echo ""
            print_info "The test will use Testcontainers to pull and start: $CURRENT_IMAGE"
            print_info "To use version $CICS_IMAGE instead, edit:"
            print_info "  $TEST_FILE"
            echo ""
            print_info "Or start the local container to skip Testcontainers:"
            print_info "  ./run-cics-container.sh run"
            echo ""
            echo -n "Continue with version $CURRENT_IMAGE? (Y/n): "
            read -r response
            if [[ "$response" =~ ^([nN][oO]|[nN])$ ]]; then
                print_info "Aborted by user"
                exit 0
            fi
        fi
    fi
    echo ""
}

verify_cics_container_connectivity() {
    print_step "Verifying CICS container connectivity..."

    # Check if container is running
    if ! docker ps | grep -q "cics-ctg-container"; then
        print_warn "CICS container 'cics-ctg-container' is not running"
        print_info "Tests will use Testcontainers to start a temporary container"
        echo ""
        return 1
    fi

    # Get container IP and port info
    CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' cics-ctg-container 2>/dev/null)
    print_info "Container detected:"
    print_info "  Container Name: cics-ctg-container"
    print_info "  Container IP: ${CONTAINER_IP:-N/A}"
    print_info "  Mapped Ports: 2006:2006, 2035:2035"

    # Test connectivity to port 2006
    print_info "Testing connectivity to localhost:2006..."
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/localhost/2006" 2>/dev/null; then
        print_info "✓ Successfully connected to CICS TG on localhost:2006"
    else
        print_warn "✗ Could not connect to localhost:2006"
        print_warn "Make sure CICS TG is fully started and listening"
        print_info "Check container logs: docker logs cics-ctg-container"
    fi

    echo ""
    return 0
}

configure_local_container() {
    print_step "Configuring tests to use local CICS container..."

    # Check if local CICS container is running
    if ! docker ps | grep -q "cics-ctg-container"; then
        print_warn "Local CICS TG container is not running"
        print_info "Tests will use Testcontainers to start a new container instance"
        echo ""
        return
    fi

    print_info "Local CICS TG container detected - configuring tests to use it"

    TEST_FILE="$REPO_DIR/$MODULE_DIR/src/test/java/com/redhat/camel/component/cics/AbstractCICSContainerizedTest.java"

    if [ ! -f "$TEST_FILE" ]; then
        print_warn "Test file not found: $TEST_FILE"
        return
    fi

    # Create a backup
    cp "$TEST_FILE" "$TEST_FILE.backup"

    # Replace the test file to use local container instead of Testcontainers
    cat > "$TEST_FILE" << 'EOF'
package com.redhat.camel.component.cics;

import org.apache.camel.test.junit5.CamelTestSupport;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Modified to use local CICS TG container instead of Testcontainers
 * Connects to localhost:2006 (local running container)
 */
public class AbstractCICSContainerizedTest extends CamelTestSupport {

    public static final Logger LOG = LoggerFactory.getLogger(AbstractCICSContainerizedTest.class);

    /**
     * Mock container object that returns localhost and fixed ports
     * This allows tests to connect to the local running CICS container
     */
    protected static final MockCTGContainer ctgContainer = new MockCTGContainer();

    @Override
    protected void doPreSetup() throws Exception {
        // Skip - using local container, not starting new one
        LOG.info("Using local CICS TG container at localhost:2006");
    }

    /**
     * Mock container class that returns localhost connection details
     */
    static class MockCTGContainer {
        public boolean isRunning() {
            return true;
        }

        public String getHost() {
            return "localhost";
        }

        public int getMappedPort(int port) {
            // Return the same port - local container uses host network
            return port;
        }

        public void start() {
            // No-op - container already running
        }
    }
}
EOF

    print_info "Test configured to use local container at localhost:2006"
    print_info "Original test file backed up to: $TEST_FILE.backup"
    echo ""
    print_warn "IMPORTANT: To see connection activity in CICS logs, run in another terminal:"
    print_warn "  docker logs -f cics-ctg-container 2>&1 | grep -E 'CTG650|connected|disconnected'"
    echo ""
}

run_tests() {
    print_step "Running Camel CICS integration tests..."
    echo ""

    # Validate settings file if provided
    if [ -n "$MAVEN_SETTINGS" ]; then
        if [ ! -f "$MAVEN_SETTINGS" ]; then
            print_error "Maven settings file not found: $MAVEN_SETTINGS"
            exit 1
        fi
        print_info "Using Maven settings: $MAVEN_SETTINGS"
    fi

    cd "$REPO_DIR/$MODULE_DIR"

    print_info "Working directory: $(pwd)"

    # Build Maven command
    MVN_CMD="mvn clean test"

    # Add settings file if provided
    if [ -n "$MAVEN_SETTINGS" ]; then
        MVN_CMD="$MVN_CMD -s $MAVEN_SETTINGS"
    fi

    # Add user-provided Maven arguments
    if [ -n "$MAVEN_ARGS" ]; then
        MVN_CMD="$MVN_CMD $MAVEN_ARGS"
    fi

    print_info "Maven command: $MVN_CMD"
    print_info "MAVEN_OPTS: ${MAVEN_OPTS:-<not set>}"
    echo ""

    print_step "Starting test execution..."
    echo "========================================================================"

    # Run Maven tests (use set +e temporarily to allow failures and capture exit code)
    set +e
    eval $MVN_CMD
    TEST_RESULT=$?
    set -e

    echo "========================================================================"
    echo ""

    if [ $TEST_RESULT -eq 0 ]; then
        print_info "Tests completed successfully!"
    else
        print_error "Tests failed with exit code: $TEST_RESULT"
    fi

    cd - > /dev/null

    # Return the test result but don't exit yet - we want to show the summary
    return $TEST_RESULT
}

show_test_summary() {
    print_step "Test Summary"
    echo ""

    SUREFIRE_REPORTS="$REPO_DIR/$MODULE_DIR/target/surefire-reports"
    SUMMARY_CSV="$WORK_DIR/test-summary.csv"
    SUMMARY_HTML="$WORK_DIR/test-summary.html"

    if [ -d "$SUREFIRE_REPORTS" ]; then
        print_info "Test reports location: $SUREFIRE_REPORTS"
        echo ""

        # Create CSV summary file
        echo "Test Class,Test Method,Result,Failure Reason" > "$SUMMARY_CSV"

        # Create HTML summary file header
        create_html_header "$SUMMARY_HTML"

        # Count test results
        TOTAL_TESTS=$(find "$SUREFIRE_REPORTS" -name "TEST-*.xml" -exec grep -h "tests=" {} \; 2>/dev/null | \
                      grep -oP 'tests="\K[0-9]+' | awk '{s+=$1} END {print s}')
        FAILED_TESTS=$(find "$SUREFIRE_REPORTS" -name "TEST-*.xml" -exec grep -h "failures=" {} \; 2>/dev/null | \
                       grep -oP 'failures="\K[0-9]+' | awk '{s+=$1} END {print s}')
        ERROR_TESTS=$(find "$SUREFIRE_REPORTS" -name "TEST-*.xml" -exec grep -h "errors=" {} \; 2>/dev/null | \
                      grep -oP 'errors="\K[0-9]+' | awk '{s+=$1} END {print s}')
        SKIPPED_TESTS=$(find "$SUREFIRE_REPORTS" -name "TEST-*.xml" -exec grep -h "skipped=" {} \; 2>/dev/null | \
                        grep -oP 'skipped="\K[0-9]+' | awk '{s+=$1} END {print s}')

        PASSED_TESTS=$((${TOTAL_TESTS:-0} - ${FAILED_TESTS:-0} - ${ERROR_TESTS:-0} - ${SKIPPED_TESTS:-0}))

        echo "  Total Tests:   ${TOTAL_TESTS:-0}"
        if [ "${PASSED_TESTS}" -gt 0 ]; then
            echo -e "  ${GREEN}Passed:        ${PASSED_TESTS}${NC}"
        fi
        if [ "${FAILED_TESTS:-0}" -gt 0 ]; then
            echo -e "  ${RED}Failed:        ${FAILED_TESTS}${NC}"
        fi
        if [ "${ERROR_TESTS:-0}" -gt 0 ]; then
            echo -e "  ${RED}Errors:        ${ERROR_TESTS}${NC}"
        fi
        if [ "${SKIPPED_TESTS:-0}" -gt 0 ]; then
            echo -e "  ${YELLOW}Skipped:       ${SKIPPED_TESTS}${NC}"
        fi
        echo ""

        # List test classes with their results and write to CSV
        print_info "Test classes executed:"
        for xml_file in "$SUREFIRE_REPORTS"/TEST-*.xml; do
            if [ -f "$xml_file" ]; then
                TEST_CLASS=$(basename "$xml_file" | sed 's/TEST-//;s/.xml$//')
                TEST_FAILURES=$(grep -oP 'failures="\K[0-9]+' "$xml_file" | head -1)
                TEST_ERRORS=$(grep -oP 'errors="\K[0-9]+' "$xml_file" | head -1)
                TEST_COUNT=$(grep -oP 'tests="\K[0-9]+' "$xml_file" | head -1)

                if [ "${TEST_FAILURES:-0}" -gt 0 ] || [ "${TEST_ERRORS:-0}" -gt 0 ]; then
                    echo -e "  ${RED}✗${NC} $TEST_CLASS (${TEST_COUNT} tests, ${TEST_FAILURES:-0} failures, ${TEST_ERRORS:-0} errors)"
                else
                    echo -e "  ${GREEN}✓${NC} $TEST_CLASS (${TEST_COUNT} tests)"
                fi

                # Parse individual test cases and write to CSV and HTML
                parse_test_cases_to_csv "$xml_file" "$TEST_CLASS" "$SUMMARY_CSV"
                parse_test_cases_to_html "$xml_file" "$TEST_CLASS" "$SUMMARY_HTML"
            fi
        done
        echo ""

        # If there are failures or errors, show details
        if [ "${FAILED_TESTS:-0}" -gt 0 ] || [ "${ERROR_TESTS:-0}" -gt 0 ]; then
            print_error "Failed/Error Test Details:"
            echo ""
            for xml_file in "$SUREFIRE_REPORTS"/TEST-*.xml; do
                if [ -f "$xml_file" ]; then
                    TEST_CLASS=$(basename "$xml_file" | sed 's/TEST-//;s/.xml$//')
                    # Look for failure or error elements
                    if grep -q '<failure' "$xml_file" || grep -q '<error' "$xml_file"; then
                        echo -e "${YELLOW}Class: $TEST_CLASS${NC}"
                        # Extract testcase names that failed
                        grep -A1 '<testcase' "$xml_file" | grep -B1 '<failure\|<error' | \
                            grep 'testcase name=' | sed 's/.*name="\([^"]*\)".*/  - \1/' || true
                        echo ""
                    fi
                fi
            done
        fi

        # Check for connection-related issues
        print_info "Checking for connection issues..."
        if grep -r "ECI_ERR_UNKNOWN_SERVER\|connection refused\|Connection refused" "$SUREFIRE_REPORTS"/*.txt 2>/dev/null | head -5; then
            echo ""
            print_warn "Connection errors detected in test output"
            print_warn "This may indicate tests are not connecting to the CICS container"
            echo ""
            print_info "Troubleshooting steps:"
            print_info "1. Verify CICS container is running: docker ps | grep cics"
            print_info "2. Check CICS logs: docker logs cics-ctg-container"
            print_info "3. Test connectivity: nc -zv localhost 2006"
            print_info "4. Monitor connections: docker logs -f cics-ctg-container 2>&1 | grep CTG650"
        else
            print_info "No obvious connection errors found in test output"
        fi
        # Close HTML file
        create_html_footer "$SUMMARY_HTML" "${TOTAL_TESTS:-0}" "${PASSED_TESTS}" "${FAILED_TESTS:-0}" "${ERROR_TESTS:-0}" "${SKIPPED_TESTS:-0}"

        # Display summary file locations
        echo ""
        print_info "Test summary files created:"
        print_info "  CSV:  $SUMMARY_CSV"
        print_info "  HTML: $SUMMARY_HTML"
        echo ""
        print_info "Summary preview (first 20 lines):"
        head -20 "$SUMMARY_CSV" | column -t -s',' 2>/dev/null || head -20 "$SUMMARY_CSV"
        echo ""
        print_info "Open HTML summary in browser:"
        print_info "  firefox $SUMMARY_HTML"
        print_info "  google-chrome $SUMMARY_HTML"
        print_info "  xdg-open $SUMMARY_HTML"
    else
        print_warn "Surefire reports directory not found: $SUREFIRE_REPORTS"
        print_warn "Tests may not have run, or Maven build failed before test execution"
    fi
    echo ""
}

create_html_header() {
    local html_file="$1"
    cat > "$html_file" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Test Execution Summary</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 20px;
            background-color: #f5f5f5;
        }
        h1 {
            color: #333;
            border-bottom: 3px solid #4CAF50;
            padding-bottom: 10px;
        }
        .summary {
            background: white;
            padding: 20px;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            margin-bottom: 20px;
        }
        .stats {
            display: flex;
            gap: 20px;
            margin: 20px 0;
        }
        .stat-box {
            flex: 1;
            padding: 20px;
            border-radius: 8px;
            text-align: center;
            color: #ffffff;
            box-shadow: 0 4px 6px rgba(0,0,0,0.3);
            border: 2px solid rgba(255,255,255,0.2);
        }
        .stat-box.total {
            background: linear-gradient(135deg, #2196F3 0%, #1976D2 100%);
        }
        .stat-box.passed {
            background: linear-gradient(135deg, #4CAF50 0%, #388E3C 100%);
        }
        .stat-box.failed {
            background: linear-gradient(135deg, #f44336 0%, #D32F2F 100%);
        }
        .stat-box.error {
            background: linear-gradient(135deg, #FF9800 0%, #F57C00 100%);
        }
        .stat-box.skipped {
            background: linear-gradient(135deg, #9E9E9E 0%, #757575 100%);
        }
        .stat-number {
            font-size: 42px;
            font-weight: bold;
            color: #ffffff !important;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.5);
            line-height: 1.2;
            margin-bottom: 8px;
        }
        .stat-label {
            font-size: 16px;
            margin-top: 5px;
            color: #ffffff !important;
            font-weight: 600;
            text-shadow: 1px 1px 2px rgba(0,0,0,0.3);
            text-transform: uppercase;
            letter-spacing: 0.5px;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            background: white;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        th {
            background-color: #4CAF50;
            color: white;
            padding: 12px;
            text-align: left;
            position: sticky;
            top: 0;
        }
        td {
            padding: 10px;
            border-bottom: 1px solid #ddd;
        }
        tr:hover { background-color: #f5f5f5; }
        .passed { color: #4CAF50; font-weight: bold; }
        .failed { color: #f44336; font-weight: bold; }
        .error { color: #FF9800; font-weight: bold; }
        .reason { color: #666; font-size: 0.9em; }
        .filter {
            margin: 10px 0;
            padding: 10px;
            background: white;
            border-radius: 5px;
        }
        .filter input {
            padding: 8px;
            width: 300px;
            border: 1px solid #ddd;
            border-radius: 4px;
        }
        .filter button {
            padding: 8px 15px;
            margin-left: 10px;
            border: none;
            border-radius: 4px;
            background: #4CAF50;
            color: white;
            cursor: pointer;
        }
        .filter button:hover { background: #45a049; }
    </style>
</head>
<body>
    <h1>🧪 Test Execution Summary</h1>
    <div class="summary">
        <p><strong>Report Generated:</strong> <span id="timestamp"></span></p>
        <p><strong>Repository:</strong> <span id="repo-type"></span></p>
        <div class="stats" id="stats-container">
            <!-- Stats will be inserted here -->
        </div>
    </div>

    <div class="filter">
        <input type="text" id="search" placeholder="Search test class or method..." onkeyup="filterTable()">
        <button onclick="filterByResult('all')">All</button>
        <button onclick="filterByResult('PASSED')" style="background:#4CAF50">Passed</button>
        <button onclick="filterByResult('FAILED')" style="background:#f44336">Failed</button>
        <button onclick="filterByResult('ERROR')" style="background:#FF9800">Error</button>
    </div>

    <table id="results-table">
        <thead>
            <tr>
                <th>Test Class</th>
                <th>Test Method</th>
                <th>Result</th>
                <th>Failure Reason</th>
            </tr>
        </thead>
        <tbody>
EOF

    # Add timestamp using JavaScript
    echo "<script>" >> "$html_file"
    echo "document.getElementById('timestamp').textContent = new Date().toLocaleString();" >> "$html_file"
    echo "document.getElementById('repo-type').textContent = '${REPO_TYPE:-Unknown}';" >> "$html_file"
    echo "</script>" >> "$html_file"
}

create_html_footer() {
    local html_file="$1"
    local total="$2"
    local passed="$3"
    local failed="$4"
    local errors="$5"
    local skipped="$6"

    cat >> "$html_file" << EOF
        </tbody>
    </table>

    <script>
        // Insert stats
        const statsHtml = \`
            <div class="stat-box total">
                <div class="stat-number">${total}</div>
                <div class="stat-label">Total Tests</div>
            </div>
            <div class="stat-box passed">
                <div class="stat-number">${passed}</div>
                <div class="stat-label">Passed</div>
            </div>
            <div class="stat-box failed">
                <div class="stat-number">${failed}</div>
                <div class="stat-label">Failed</div>
            </div>
            <div class="stat-box error">
                <div class="stat-number">${errors}</div>
                <div class="stat-label">Errors</div>
            </div>
            <div class="stat-box skipped">
                <div class="stat-number">${skipped}</div>
                <div class="stat-label">Skipped</div>
            </div>
        \`;
        document.getElementById('stats-container').innerHTML = statsHtml;

        // Filter functionality
        function filterTable() {
            const input = document.getElementById('search');
            const filter = input.value.toUpperCase();
            const table = document.getElementById('results-table');
            const rows = table.getElementsByTagName('tr');

            for (let i = 1; i < rows.length; i++) {
                const cells = rows[i].getElementsByTagName('td');
                let found = false;

                for (let j = 0; j < cells.length; j++) {
                    if (cells[j].textContent.toUpperCase().indexOf(filter) > -1) {
                        found = true;
                        break;
                    }
                }

                rows[i].style.display = found ? '' : 'none';
            }
        }

        function filterByResult(result) {
            const table = document.getElementById('results-table');
            const rows = table.getElementsByTagName('tr');

            for (let i = 1; i < rows.length; i++) {
                const resultCell = rows[i].getElementsByTagName('td')[2];
                if (result === 'all' || resultCell.textContent === result) {
                    rows[i].style.display = '';
                } else {
                    rows[i].style.display = 'none';
                }
            }
        }
    </script>
</body>
</html>
EOF
}

parse_test_cases_to_csv() {
    local xml_file="$1"
    local test_class="$2"
    local output_csv="$3"

    # Use awk to parse XML and extract all testcase elements
    awk '
    /<testcase/ {
        in_testcase=1
        testcase_content=$0
        # Extract test method name
        match($0, /name="([^"]+)"/, arr)
        test_name=arr[1]

        # Check if self-closing
        if ($0 ~ /\/>/) {
            print "\"'"$test_class"'\",\"" test_name "\",\"PASSED\",\"\"" >> "'"$output_csv"'"
            in_testcase=0
            next
        }
    }

    in_testcase && /<\/testcase>/ {
        testcase_content = testcase_content "\n" $0

        # Determine result
        result="PASSED"
        reason=""

        if (testcase_content ~ /<failure/) {
            result="FAILED"
            match(testcase_content, /message="([^"]+)"/, arr)
            reason=arr[1]
            gsub(/"/, "\"\"", reason)
        } else if (testcase_content ~ /<error/) {
            result="ERROR"
            match(testcase_content, /message="([^"]+)"/, arr)
            reason=arr[1]
            gsub(/"/, "\"\"", reason)
        } else if (testcase_content ~ /<skipped/) {
            result="SKIPPED"
            match(testcase_content, /message="([^"]+)"/, arr)
            reason=arr[1]
            gsub(/"/, "\"\"", reason)
        }

        print "\"'"$test_class"'\",\"" test_name "\",\"" result "\",\"" reason "\"" >> "'"$output_csv"'"
        in_testcase=0
        testcase_content=""
    }

    in_testcase {
        testcase_content = testcase_content "\n" $0
    }
    ' "$xml_file"
}

parse_test_cases_to_html() {
    local xml_file="$1"
    local test_class="$2"
    local output_html="$3"

    # Use awk to parse XML and extract all testcase elements
    awk '
    /<testcase/ {
        in_testcase=1
        testcase_content=$0
        # Extract test method name
        match($0, /name="([^"]+)"/, arr)
        test_name=arr[1]

        # Check if self-closing
        if ($0 ~ /\/>/) {
            print "<tr><td>'"$test_class"'</td><td>" test_name "</td><td class=\"passed\">PASSED</td><td class=\"reason\"></td></tr>" >> "'"$output_html"'"
            in_testcase=0
            next
        }
    }

    in_testcase && /<\/testcase>/ {
        testcase_content = testcase_content "\n" $0

        # Determine result
        result="PASSED"
        css_class="passed"
        reason=""

        if (testcase_content ~ /<failure/) {
            result="FAILED"
            css_class="failed"
            match(testcase_content, /message="([^"]+)"/, arr)
            reason=arr[1]
            gsub(/</, "\\&lt;", reason)
            gsub(/>/, "\\&gt;", reason)
        } else if (testcase_content ~ /<error/) {
            result="ERROR"
            css_class="error"
            match(testcase_content, /message="([^"]+)"/, arr)
            reason=arr[1]
            gsub(/</, "\\&lt;", reason)
            gsub(/>/, "\\&gt;", reason)
        } else if (testcase_content ~ /<skipped/) {
            result="SKIPPED"
            css_class="skipped"
            match(testcase_content, /message="([^"]+)"/, arr)
            reason=arr[1]
            gsub(/</, "\\&lt;", reason)
            gsub(/>/, "\\&gt;", reason)
        }

        print "<tr><td>'"$test_class"'</td><td>" test_name "</td><td class=\"" css_class "\">" result "</td><td class=\"reason\">" reason "</td></tr>" >> "'"$output_html"'"
        in_testcase=0
        testcase_content=""
    }

    in_testcase {
        testcase_content = testcase_content "\n" $0
    }
    ' "$xml_file"
}

cleanup() {
    print_step "Cleanup"
    echo ""
    print_info "To remove the cloned repository:"
    print_info "  rm -rf $WORK_DIR"
    echo ""
    print_info "To remove Docker test containers:"
    print_info "  docker ps -a | grep testcontainers | awk '{print \$1}' | xargs docker rm -f"
}

# Main execution
main() {
    # Parse command line arguments
    local POSITIONAL_MODE=false

    while [[ $# -gt 0 ]]; do
        # Once we've seen the branch, everything else is Maven args (even if starts with -)
        if [[ "$POSITIONAL_MODE" == "true" ]]; then
            MAVEN_ARGS="$1"
            shift
        else
            case $1 in
                -s|--settings)
                    MAVEN_SETTINGS="$2"
                    shift 2
                    ;;
                -r|--repo-type)
                    REPO_TYPE="$2"
                    # Validate repo type
                    if [[ "$REPO_TYPE" != "middlestream" && "$REPO_TYPE" != "downstream" ]]; then
                        print_error "Invalid repository type: $REPO_TYPE"
                        print_error "Valid values are: middlestream, downstream"
                        exit 1
                    fi
                    shift 2
                    ;;
                -h|--help)
                    show_usage
                    exit 0
                    ;;
                --)
                    # Explicit end of options marker
                    POSITIONAL_MODE=true
                    shift
                    ;;
                -*)
                    # Check if we already have branch - if so, this is Maven args
                    if [ -n "$BRANCH" ]; then
                        MAVEN_ARGS="$1"
                        shift
                    else
                        print_error "Unknown option: $1"
                        echo ""
                        show_usage
                        exit 1
                    fi
                    ;;
                *)
                    # First positional argument is branch
                    if [ -z "$BRANCH" ]; then
                        BRANCH="$1"
                        POSITIONAL_MODE=true
                    else
                        # Second positional argument is Maven args
                        MAVEN_ARGS="$1"
                    fi
                    shift
                    ;;
            esac
        fi
    done

    # Set defaults for positional arguments
    BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
    REPO_TYPE="${REPO_TYPE:-$DEFAULT_REPO_TYPE}"

    echo ""
    print_info "Camel CICS Integration Test Runner"
    print_info "=================================="
    echo ""
    print_info "Repository Type: $REPO_TYPE"
    if [ "$REPO_TYPE" = "downstream" ]; then
        print_info "Repository URL: $DOWNSTREAM_REPO_URL"
    else
        print_info "Repository URL: $MIDDLESTREAM_REPO_URL"
    fi
    print_info "Branch: $BRANCH"
    print_info "Image: $CICS_IMAGE"
    if [ -n "$MAVEN_SETTINGS" ]; then
        print_info "Maven Settings: $MAVEN_SETTINGS"
    fi
    echo ""

    check_prerequisites
    check_ctg_client
    clone_repository
    check_cics_image
    update_test_image_version
    verify_cics_container_connectivity
    configure_local_container

    # Disable set -e temporarily to allow run_tests to fail without exiting
    set +e
    run_tests
    TEST_EXIT_CODE=$?
    set -e

    # Always show test summary, even if tests failed
    show_test_summary
    cleanup

    echo ""
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        print_info "Test execution complete!"
    else
        print_error "Test execution completed with failures (exit code: $TEST_EXIT_CODE)"
        echo ""
        print_info "Check the detailed test reports at:"
        print_info "  $REPO_DIR/$MODULE_DIR/target/surefire-reports/"
        exit $TEST_EXIT_CODE
    fi
}

# Run main function
main "$@"
