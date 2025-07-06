#!/bin/bash
#SBATCH --job-name=ml_simulation
#SBATCH --output=ml_simulation_%j.out
#SBATCH --error=ml_simulation_%j.err
#SBATCH --time=00:20:00
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=2
#SBATCH --partition=compute

echo "Machine Learning Simulation Job"
echo "Job ID: $SLURM_JOB_ID"
echo "Node: $SLURM_JOB_NODELIST"
echo "CPUs allocated: $SLURM_CPUS_PER_TASK"
echo "Date: $(date)"

# Create a machine learning simulation script
cat > ml_simulation.py << 'EOF'
#!/usr/bin/env python3
"""
Machine Learning Simulation: Classification on Synthetic Dataset
Demonstrates ML workflow in HPC environment
"""

import numpy as np
import matplotlib
matplotlib.use('Agg')  # Non-interactive backend for HPC
import matplotlib.pyplot as plt
from sklearn.datasets import make_classification, make_regression
from sklearn.model_selection import train_test_split, cross_val_score
from sklearn.ensemble import RandomForestClassifier, RandomForestRegressor
from sklearn.linear_model import LogisticRegression, LinearRegression
from sklearn.svm import SVC
from sklearn.metrics import accuracy_score, classification_report, mean_squared_error, r2_score
from sklearn.preprocessing import StandardScaler
import time
import os

def classification_experiment():
    """Run classification experiment"""
    print("=== Classification Experiment ===")
    
    # Generate synthetic dataset
    X, y = make_classification(
        n_samples=5000,
        n_features=20,
        n_informative=15,
        n_redundant=5,
        n_classes=3,
        random_state=42
    )
    
    print(f"Dataset shape: {X.shape}")
    print(f"Classes: {np.unique(y)}")
    
    # Split data
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42, stratify=y
    )
    
    # Scale features
    scaler = StandardScaler()
    X_train_scaled = scaler.fit_transform(X_train)
    X_test_scaled = scaler.transform(X_test)
    
    # Models to compare
    models = {
        'Random Forest': RandomForestClassifier(n_estimators=100, random_state=42),
        'Logistic Regression': LogisticRegression(random_state=42, max_iter=1000),
        'SVM': SVC(random_state=42, probability=True)
    }
    
    results = {}
    
    for name, model in models.items():
        print(f"\nTraining {name}...")
        start_time = time.time()
        
        # Train model
        if name == 'SVM':
            model.fit(X_train_scaled, y_train)
            y_pred = model.predict(X_test_scaled)
        else:
            model.fit(X_train_scaled if name == 'Logistic Regression' else X_train, y_train)
            y_pred = model.predict(X_test_scaled if name == 'Logistic Regression' else X_test)
        
        # Evaluate
        accuracy = accuracy_score(y_test, y_pred)
        train_time = time.time() - start_time
        
        # Cross-validation
        cv_scores = cross_val_score(
            model, 
            X_train_scaled if name in ['Logistic Regression', 'SVM'] else X_train, 
            y_train, 
            cv=5
        )
        
        results[name] = {
            'accuracy': accuracy,
            'cv_mean': cv_scores.mean(),
            'cv_std': cv_scores.std(),
            'train_time': train_time
        }
        
        print(f"  Accuracy: {accuracy:.4f}")
        print(f"  CV Score: {cv_scores.mean():.4f} (±{cv_scores.std():.4f})")
        print(f"  Train Time: {train_time:.3f}s")
    
    return results

def regression_experiment():
    """Run regression experiment"""
    print("\n=== Regression Experiment ===")
    
    # Generate synthetic regression dataset
    X, y = make_regression(
        n_samples=3000,
        n_features=15,
        noise=0.1,
        random_state=42
    )
    
    print(f"Dataset shape: {X.shape}")
    
    # Split data
    X_train, X_test, y_train, y_test = train_test_split(
        X, y, test_size=0.2, random_state=42
    )
    
    # Scale features
    scaler = StandardScaler()
    X_train_scaled = scaler.fit_transform(X_train)
    X_test_scaled = scaler.transform(X_test)
    
    # Models
    models = {
        'Random Forest': RandomForestRegressor(n_estimators=100, random_state=42),
        'Linear Regression': LinearRegression()
    }
    
    results = {}
    
    for name, model in models.items():
        print(f"\nTraining {name}...")
        start_time = time.time()
        
        # Train
        X_train_use = X_train_scaled if name == 'Linear Regression' else X_train
        X_test_use = X_test_scaled if name == 'Linear Regression' else X_test
        
        model.fit(X_train_use, y_train)
        y_pred = model.predict(X_test_use)
        
        # Evaluate
        mse = mean_squared_error(y_test, y_pred)
        r2 = r2_score(y_test, y_pred)
        train_time = time.time() - start_time
        
        results[name] = {
            'mse': mse,
            'r2': r2,
            'train_time': train_time
        }
        
        print(f"  MSE: {mse:.4f}")
        print(f"  R²: {r2:.4f}")
        print(f"  Train Time: {train_time:.3f}s")
    
    return results

def create_visualizations(class_results, reg_results):
    """Create result visualizations"""
    print("\n=== Creating Visualizations ===")
    
    fig, axes = plt.subplots(2, 2, figsize=(12, 10))
    
    # Classification accuracy comparison
    models = list(class_results.keys())
    accuracies = [class_results[m]['accuracy'] for m in models]
    cv_scores = [class_results[m]['cv_mean'] for m in models]
    
    x = np.arange(len(models))
    axes[0, 0].bar(x - 0.2, accuracies, 0.4, label='Test Accuracy', alpha=0.8)
    axes[0, 0].bar(x + 0.2, cv_scores, 0.4, label='CV Score', alpha=0.8)
    axes[0, 0].set_xlabel('Models')
    axes[0, 0].set_ylabel('Accuracy')
    axes[0, 0].set_title('Classification Performance')
    axes[0, 0].set_xticks(x)
    axes[0, 0].set_xticklabels(models, rotation=45)
    axes[0, 0].legend()
    axes[0, 0].grid(True, alpha=0.3)
    
    # Training time comparison
    class_times = [class_results[m]['train_time'] for m in models]
    axes[0, 1].bar(models, class_times, color='orange', alpha=0.8)
    axes[0, 1].set_xlabel('Models')
    axes[0, 1].set_ylabel('Training Time (s)')
    axes[0, 1].set_title('Training Time Comparison')
    plt.setp(axes[0, 1].xaxis.get_majorticklabels(), rotation=45)
    axes[0, 1].grid(True, alpha=0.3)
    
    # Regression performance
    reg_models = list(reg_results.keys())
    r2_scores = [reg_results[m]['r2'] for m in reg_models]
    axes[1, 0].bar(reg_models, r2_scores, color='green', alpha=0.8)
    axes[1, 0].set_xlabel('Models')
    axes[1, 0].set_ylabel('R² Score')
    axes[1, 0].set_title('Regression Performance')
    axes[1, 0].grid(True, alpha=0.3)
    
    # Performance summary
    all_models = models + reg_models
    all_times = class_times + [reg_results[m]['train_time'] for m in reg_models]
    colors = ['blue'] * len(models) + ['red'] * len(reg_models)
    
    axes[1, 1].bar(range(len(all_models)), all_times, color=colors, alpha=0.8)
    axes[1, 1].set_xlabel('All Models')
    axes[1, 1].set_ylabel('Training Time (s)')
    axes[1, 1].set_title('Overall Training Time')
    axes[1, 1].set_xticks(range(len(all_models)))
    axes[1, 1].set_xticklabels(all_models, rotation=45, ha='right')
    axes[1, 1].grid(True, alpha=0.3)
    
    plt.tight_layout()
    
    job_id = os.environ.get('SLURM_JOB_ID', 'test')
    output_file = f'ml_results_{job_id}.png'
    plt.savefig(output_file, dpi=150, bbox_inches='tight')
    print(f"Results saved to: {output_file}")

def main():
    """Main simulation function"""
    print("=== Machine Learning HPC Simulation ===")
    print(f"Job ID: {os.environ.get('SLURM_JOB_ID', 'unknown')}")
    print(f"Node: {os.environ.get('SLURMD_NODENAME', 'unknown')}")
    
    # Run experiments
    class_results = classification_experiment()
    reg_results = regression_experiment()
    
    # Create visualizations
    create_visualizations(class_results, reg_results)
    
    # Summary
    print("\n=== Experiment Summary ===")
    print("Classification Results:")
    for model, results in class_results.items():
        print(f"  {model}: {results['accuracy']:.4f} accuracy in {results['train_time']:.3f}s")
    
    print("\nRegression Results:")
    for model, results in reg_results.items():
        print(f"  {model}: {results['r2']:.4f} R² in {results['train_time']:.3f}s")
    
    print("\nSimulation completed successfully!")

if __name__ == "__main__":
    main()
EOF

echo "Running machine learning simulation..."
python3 ml_simulation.py

echo "=== Job Results ==="
ls -la *.png 2>/dev/null || echo "No plots generated"
echo "Job completed on $(date)"
