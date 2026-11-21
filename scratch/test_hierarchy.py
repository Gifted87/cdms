import math

class MatrixProcessor:
    def __init__(self, data):
        self.data = data
        
    def process(self):
        def local_helper():
            return math.sqrt(16)
        return local_helper()

def global_worker():
    return True
