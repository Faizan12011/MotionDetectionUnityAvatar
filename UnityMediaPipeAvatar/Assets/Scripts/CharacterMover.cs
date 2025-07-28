using UnityEngine;
using UnityEngine.UIElements;

public class CharacterMover : MonoBehaviour
{
    // Start is called once before the first execution of Update after the MonoBehaviour is created
    void Start()
    {
        
    }

    // Update is called once per frame
    void Update()
    {
        float v = Input.GetAxis("Vertical");

        transform.Translate(transform.forward * v * -5 * Time.deltaTime);
        //Debug.Log(transform.position);
    }
}
