# Piston — Multi-Server Test Results

> **Last Run:** 2026-10-13  
> **Script:** `test_all_servers.sh`  
> **Servers Tested:**
> | Label | IP |
> |---|---|
> | old/reference | `178.162.205.144` |
> | new server 1 | `78.159.100.10` |
> | new server 2 | `46.165.225.12` |

---

## Summary

| Test | 178.162.205.144 (old) | 78.159.100.10 (new 1) | 46.165.225.12 (new 2) |
|---|:---:|:---:|:---:|
| Python 3.12 | ✅ | ✅ | ✅ |
| Python 3.10 | ✅ | ✅ | ✅ |
| Node.js 20 | ✅ | ✅ | ✅ |
| TypeScript 5 | ✅ | ✅ | ✅ |
| Java 15 | ✅ | ✅ | ✅ |
| C (gcc 10) | ✅ | ✅ | ✅ |
| Go 1.16 | ❌ code=1 | ✅ | ✅ |
| Rust 1.68 | ❌ unknown runtime | ✅ | ✅ |
| Bash 5.2 | ❌ unknown runtime | ✅ | ✅ |
| SQLite3 3.36 | ✅ | ✅ | ✅ |
| Python DS / NumPy | ❌ unknown runtime | ✅ | ✅ |
| Python DS / Pandas | ❌ unknown runtime | ✅ | ✅ |
| Python DS / Matplotlib | ❌ unknown runtime | ✅ | ✅ |
| Python DS / Seaborn | ❌ unknown runtime | ✅ | ✅ |
| Python DS / scikit-learn | ❌ unknown runtime | ✅ | ✅ |
| Python DS / SciPy | ❌ unknown runtime | ✅ | ✅ |
| Python DS / Pillow | ❌ unknown runtime | ✅ | ✅ |
| Python DS / Statsmodels | ❌ unknown runtime | ✅ | ✅ |
| Python DS / Plotly | ❌ unknown runtime | ✅ | ✅ |
| C++ (g++ 10) | ✅ | ✅ | ✅ |
| **[BUG-REPRO] Python multi-file File I/O** | ✅ | ✅ | ✅ |
| Python multi-file write+read | ✅ | ✅ | ✅ |
| Java multi-file OOP | ❌ code=1 | ❌ code=1 | ❌ code=1 |
| Python empty stdin | ✅ | ✅ | ✅ |
| Python multiline stdin | ✅ | ✅ | ✅ |

---

## New Server Health (78.159.100.10 & 46.165.225.12)

Both new servers are **fully healthy**. All supported runtimes pass. ✅

---

## Issues Found

### ❌ Java multi-file OOP — fails on ALL servers (code=1, empty stdout)

The test sends `Animal.java` + `Main.java` as two separate files. Piston compiles the **first file listed** as the entry point; `Animal.java` has no `main()` method so compilation succeeds but execution fails.

**Fix for the test:** Swap file order so `Main.java` is first, or combine into one file for the test.

---

### ❌ Old/Reference server (178.162.205.144) — multiple missing runtimes

The old server is missing several runtimes that are present on the new servers:

| Missing Runtime | Status |
|---|---|
| `rust-1.68.2` | ❌ unknown |
| `bash-5.2.0` | ❌ unknown |
| `python-datascience-3.12.7` | ❌ unknown |
| `go-1.16.2` | ❌ exits code=1 |

> **Conclusion:** Old server is a legacy reference only. The two new VPS servers (`78.159.100.10`, `46.165.225.12`) are the production-ready deployments and should be used exclusively.

---

## Bug Repro Confirmation ✅

The `[BUG-REPRO] Python multi-file File I/O` test confirms the fix is working:

- **Test:** Sends `main.py` (reads `data.txt`) + `data.txt` (content: `hello from file`) as multi-file payload
- **Expected output:** `hello from file`
- **Result:** ✅ All 3 servers return exactly `hello from file`

The previously reported bug (Python env prefix being prepended to ALL files including `.txt` data files) is **confirmed fixed**.

---

## Java Test Snippets (Manual Reference)

### Phase 1: File I/O

#### Write + Read in One Run

```java
import java.io.*;

public class Main {
    public static void main(String[] args) throws IOException {
        // Write
        FileWriter fw = new FileWriter("hello.txt");
        fw.write("Hello from Piston!\nLine 2\nLine 3");
        fw.close();

        // Read back
        BufferedReader br = new BufferedReader(new FileReader("hello.txt"));
        String line;
        while ((line = br.readLine()) != null) {
            System.out.println(line);
        }
        br.close();
    }
}
```

---

### Phase 2: OOP Concepts

#### Concept 1 — Inheritance + Method Overriding

**Animal.java** (workspace file)
```java
public class Animal {
    String name;

    public Animal(String name) {
        this.name = name;
    }

    public String speak() {
        return name + " makes a sound.";
    }
}
```

**Main.java** (entry point — must be listed first in files array)
```java
public class Main extends Animal {
    public Main(String name) {
        super(name);
    }

    @Override
    public String speak() {
        return name + " says: Woof!";
    }

    public static void main(String[] args) {
        Animal a = new Animal("Cat");
        Animal d = new Main("Dog");

        System.out.println(a.speak());
        System.out.println(d.speak());
    }
}
```

Expected output:
```
Cat makes a sound.
Dog says: Woof!
```

#### Concept 2 — Interface + Polymorphism

**Shape.java** (workspace)
```java
public interface Shape {
    double area();
    default String describe() {
        return "I am a shape with area: " + area();
    }
}

class Circle implements Shape {
    double radius;
    Circle(double r) { this.radius = r; }
    public double area() { return Math.PI * radius * radius; }
}

class Rectangle implements Shape {
    double w, h;
    Rectangle(double w, double h) { this.w = w; this.h = h; }
    public double area() { return w * h; }
}
```

**Main.java**
```java
public class Main {
    public static void main(String[] args) {
        Shape[] shapes = { new Circle(5), new Rectangle(4, 6) };
        for (Shape s : shapes) {
            System.out.printf("%.2f - %s%n", s.area(), s.describe());
        }
    }
}
```

#### Concept 3 — Encapsulation + Static Members

```java
public class Main {
    static int count = 0;

    private String name;
    private int id;

    public Main(String name) {
        this.name = name;
        this.id = ++count;
    }

    public String getName() { return name; }
    public int getId() { return id; }

    public static void main(String[] args) {
        Main a = new Main("Alice");
        Main b = new Main("Bob");
        Main c = new Main("Charlie");

        System.out.println("Total created: " + count);
        for (Main m : new Main[]{a, b, c}) {
            System.out.println("ID " + m.getId() + ": " + m.getName());
        }
    }
}
```

Expected output:
```
Total created: 3
ID 1: Alice
ID 2: Bob
ID 3: Charlie
```
