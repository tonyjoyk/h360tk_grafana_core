from behave import given, when, then

# A simple class to simulate the application code we are testing
class Calculator:
    def __init__(self):
        self.result = 0

    def add(self, num1, num2):
        self.result = num1 + num2
        return self.result


@given('I have a calculator')
def step_impl(context):
    # 'context' is a shared object passed between steps to store data
    context.calc = Calculator()

@when('I enter "{num1}" and "{num2}"')
def step_impl(context, num1, num2):
    # Parameters extracted from the feature text are passed as strings by default
    context.result = context.calc.add(int(num1), int(num2))

@then('the result should be "{expected_result}"')
def step_impl(context, expected_result):
    assert context.result == int(expected_result), f"Expected {expected_result} but got {context.result}"
