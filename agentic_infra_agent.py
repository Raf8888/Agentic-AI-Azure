"""
agentic_infra_agent.py
======================

This file provides a very simple example of how you might start building an
agentic infrastructure assistant using the Microsoft Agent Framework.  The
Agent Framework unifies the low‑level building blocks from the Semantic Kernel
and AutoGen projects and allows you to register your own functions as
“tools” that the agent can call.  Because the Python API for the Agent
Framework is still evolving (and the official documentation is limited as of
October 2025), this script should be treated as a conceptual starting point
rather than a drop‑in solution.

The agent defined here exposes two functions as tools:

1. **terraform_apply** – runs `terraform plan` and `terraform apply` in a
   directory you specify.  It returns the output from the Terraform command so
   you can see what resources were created or modified.  You could extend
   this to take variables or a plan file as arguments.

2. **az_cli** – executes an arbitrary Azure CLI command and returns the
   resulting text output.  For safety you should curate which commands are
   allowed and possibly implement your own wrappers instead of passing
   arbitrary strings from a user prompt.

To use this script on your VM you need:

* Python 3.9 or later and `pip`.
* The `agent-framework` package installed via `pip install agent-framework`.
* Access to an LLM provider supported by the Agent Framework (for example
  Azure OpenAI or OpenAI).  You must set environment variables for your
  endpoint, API key and model deployment.

This script demonstrates the basic wiring required to:

* define tool functions,
* register them with an agent,
* forward a user message to the agent and stream the response.

You can adapt this example by adding more sophisticated tools (such as
functions that call the Palo Alto firewall API) and by changing the
instructions to guide the agent’s behaviour.

Note that this script is **not** intended to be run by the agent itself in
this environment; rather it is provided as a reference for you to copy to
your VM and run there.  You will interact with the script via a terminal
session on the VM (SSH) or by embedding it into a web application.
"""

import os
import subprocess
from typing import Iterable

try:
    # Attempt to import the pan-os Python SDK.  This library allows the agent to
    # interact with Palo Alto Networks firewalls and Panorama devices via the
    # API.  If it is not installed on your VM, you can add it with
    # `pip install pan-os-python`.  The optional dependency is imported here so
    # the rest of the script can still run even if the library is missing.
    from panos.firewall import Firewall  # type: ignore
    from panos.objects import AddressObject  # type: ignore
except Exception:
    # Do not raise an error here; the functions that rely on panos will catch
    # ImportError and return helpful messages at runtime.
    Firewall = None  # type: ignore
    AddressObject = None  # type: ignore

try:
    # Attempt to import the Agent Framework.  If it’s not installed you must
    # install it on your VM via `pip install agent-framework`.
    from agent_framework import ChatAgent, ai_function, ChatCompletionModel, OpenAICredentials
except ImportError as e:
    raise ImportError(
        "The agent-framework package is not installed. Install it with `pip install agent-framework` "
        "and ensure you're running this script on a system with internet access."
    ) from e


def run_terraform(directory: str, auto_approve: bool = False) -> str:
    """Run `terraform plan` and optionally `terraform apply` in the given directory.

    :param directory: Path to the directory containing your Terraform configuration.
    :param auto_approve: If True, automatically apply the plan without prompting.
    :return: Combined stdout/stderr from the Terraform commands.
    """
    # Ensure the directory exists
    if not os.path.isdir(directory):
        return f"Terraform directory not found: {directory}"

    commands = []
    # Always run `terraform init` to make sure providers are downloaded
    commands.append(["terraform", "init", "-input=false"])
    # Create a plan file so that apply can be conditional
    plan_file = os.path.join(directory, "plan.tfplan")
    commands.append([
        "terraform",
        "plan",
        "-input=false",
        f"-out={plan_file}",
    ])
    if auto_approve:
        commands.append([
            "terraform",
            "apply",
            "-input=false",
            "-auto-approve",
            plan_file,
        ])
    else:
        commands.append([
            "terraform",
            "apply",
            "-input=false",
            plan_file,
        ])

    output_lines: list[str] = []
    for cmd in commands:
        try:
            proc = subprocess.run(
                cmd,
                cwd=directory,
                capture_output=True,
                text=True,
                check=False,
            )
            output_lines.append(f"$ {' '.join(cmd)}\n{proc.stdout}\n{proc.stderr}")
        except FileNotFoundError:
            return "Terraform binary not found. Ensure Terraform is installed and available on the PATH."

    return "\n".join(output_lines)


def run_paloalto_create_address_object(
    host: str,
    username: str,
    password: str,
    object_name: str,
    ip_address: str,
    description: str = "",
) -> str:
    """Create an address object on a Palo Alto firewall.

    This helper uses the pan-os Python SDK to connect to a PAN‑OS device and
    push a new address object.  It requires the `pan-os-python` package to be
    installed on your VM (`pip install pan-os-python`).

    :param host: Management IP or hostname of the firewall.
    :param username: API username with permissions to create objects.
    :param password: Password for the API user.
    :param object_name: Name of the address object to create.
    :param ip_address: IP address or FQDN for the object.
    :param description: Optional description for the object.
    :return: A message indicating success or failure.
    """
    if Firewall is None or AddressObject is None:
        return (
            "pan-os-python is not installed. Install it with `pip install pan-os-python` "
            "to enable Palo Alto firewall integration."
        )
    try:
        fw = Firewall(host, username, password)
        # Construct and push the address object
        obj = AddressObject(object_name, ip_address, description=description)
        fw.add(obj)
        obj.create()
        return f"Address object '{object_name}' created on firewall {host}."
    except Exception as e:
        return f"Error creating address object on firewall {host}: {e}"


def run_azure_cli(command: str) -> str:
    """Execute an Azure CLI command and return its output.

    The command should not include the leading `az` – for example, provide
    "vm list -g myResourceGroup" to list VMs.  This function prepends `az` and
    executes the command.

    :param command: Azure CLI command arguments (without the leading `az`).
    :return: Combined stdout/stderr from the Azure CLI invocation.
    """
    full_cmd = ["az"] + command.split()
    try:
        proc = subprocess.run(
            full_cmd,
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.stdout + proc.stderr
    except FileNotFoundError:
        return "Azure CLI not found. Please install the Azure CLI on this machine."


# Register tool functions with the agent using the `@ai_function` decorator.  The
# decorator exposes the Python function to the LLM runtime and generates a
# schema so the agent knows what parameters the function accepts.  Note: the
# decorator API may change as the Agent Framework evolves; consult the
# documentation for the version you’re using.

@ai_function("terraform_apply", description="Run Terraform plan and apply in the specified directory")
def terraform_apply(directory: str, auto_approve: bool = False) -> str:  # type: ignore[override]
    return run_terraform(directory, auto_approve)


@ai_function("azure_cli", description="Run an Azure CLI command (without the leading 'az')")
def azure_cli(command: str) -> str:  # type: ignore[override]
    return run_azure_cli(command)


@ai_function(
    "paloalto_create_address_object",
    description=(
        "Create an address object on a Palo Alto firewall. Provide the firewall's host, "
        "username, password, the desired object name, IP address, and optional description."
    ),
)
def paloalto_create_address_object(
    host: str,
    username: str,
    password: str,
    object_name: str,
    ip_address: str,
    description: str = "",
) -> str:  # type: ignore[override]
    return run_paloalto_create_address_object(host, username, password, object_name, ip_address, description)


def build_agent() -> ChatAgent:
    """Construct the chat agent with credentials, instructions and tools.

    Returns a ChatAgent instance configured to use your preferred model.  You
    must set the following environment variables before running this script:

    * `OPENAI_API_TYPE` – set to `azure` for Azure OpenAI or `openai` for the
      public OpenAI service.
    * `OPENAI_API_KEY` – your API key.
    * `OPENAI_API_BASE` – the endpoint URL for your Azure OpenAI resource (e.g.
      https://my-resource.openai.azure.com/) or https://api.openai.com/v1 for
      OpenAI.
    * `OPENAI_DEPLOYMENT_NAME` – the deployment name of your model (e.g.
      gpt-4o).  Required for Azure OpenAI.

    You can adapt these environment variables to your own secrets manager or
    configuration system.  See the Agent Framework documentation for
    additional options (DefaultAzureCredential, etc.).
    """
    # Read credentials from environment
    api_type = os.environ.get("OPENAI_API_TYPE", "azure")
    api_key = os.environ.get("OPENAI_API_KEY")
    api_base = os.environ.get("OPENAI_API_BASE")
    deployment_name = os.environ.get("OPENAI_DEPLOYMENT_NAME")

    if not api_key or not api_base:
        raise RuntimeError(
            "Missing OPENAI_API_KEY or OPENAI_API_BASE. Set these environment variables "
            "before running the agent."
        )

    creds = OpenAICredentials(api_key=api_key, api_base=api_base, api_type=api_type)
    model = ChatCompletionModel(deployment=deployment_name, credentials=creds)

    # Instructions guide the agent’s behaviour.  Adjust these to suit your
    # environment.  For example, you might specify which directory contains
    # Terraform configs or which Azure resource group to manage.
    system_instructions = (
        "You are an infrastructure automation assistant. When the user asks "
        "you to provision or modify Azure or Palo Alto firewall resources, use the available tools "
        "(terraform_apply, azure_cli or paloalto_create_address_object) to perform the requested operations. "
        "Explain each step you take before executing commands. Always summarise "
        "the results."
    )

    agent = ChatAgent(
        instructions=system_instructions,
        model=model,
        tools=[terraform_apply, azure_cli, paloalto_create_address_object],
        name="InfrastructureAgent",
    )
    return agent


def chat_loop(agent: ChatAgent) -> None:
    """Simple REPL loop to interact with the agent via the console.

    This function sends user input to the agent and prints the agent’s responses.
    Use Ctrl+C to exit the loop.
    """
    print("Infrastructure agent ready. Type your requests and press Enter. Ctrl+C to exit.")
    while True:
        try:
            user_input = input("You: ")
        except KeyboardInterrupt:
            print("\nExiting.")
            return
        # Forward the input to the agent and stream the response.  The
        # Agent Framework may support both synchronous and streaming APIs.
        # Here we call the synchronous API for simplicity.
        try:
            response = agent.run(user_input)  # type: ignore[attr-defined]
        except Exception as ex:
            print(f"Error while processing request: {ex}")
            continue
        print(f"Agent: {response}")


if __name__ == "__main__":
    agent = build_agent()
    chat_loop(agent)